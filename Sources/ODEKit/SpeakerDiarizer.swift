import AVFoundation
import FluidAudio

/// Streaming speaker diarization (NVIDIA Sortformer via FluidAudio, CoreML).
///
/// ODE already separates "You" (your mic) from "Others" (incoming call audio)
/// at the channel level; this distinguishes *between* the remote participants.
/// Feed it the same incoming audio the transcriber gets, then ask which
/// speaker was talking during a segment's time span to sub-label "Others" as
/// "Speaker 1/2/…" (up to 4 speaker slots).
@available(macOS 14.0, *)
public final class SpeakerDiarizer {
    private let diarizer = SortformerDiarizer()
    /// Serializes feeds/queries and keeps Sortformer inference off the
    /// audio-callback thread.
    private let queue = DispatchQueue(label: "ode.diarizer", qos: .utility)
    private var converter: AVAudioConverter?

    /// Sortformer consumes 16 kHz mono float.
    private static let feedFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
        channels: 1, interleaved: false)!

    public init() {}

    // MARK: - Shared model cache

    private static let modelsLock = NSLock()
    private static var modelsTask: Task<SortformerModels, Error>?

    private static func sharedModels(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> SortformerModels {
        modelsLock.lock()
        let task: Task<SortformerModels, Error>
        if let existing = modelsTask {
            task = existing
        } else {
            task = Task {
                try await SortformerModels.loadFromHuggingFace(
                    config: .default,
                    progressHandler: { p in progress?(p.fractionCompleted) })
            }
            modelsTask = task
        }
        modelsLock.unlock()
        do {
            return try await task.value
        } catch {
            modelsLock.lock()
            modelsTask = nil
            modelsLock.unlock()
            throw error
        }
    }

    /// Ensure the Sortformer model is downloaded and loadable (first run
    /// downloads the weights, cached afterwards).
    public static func ensureModel(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await sharedModels(progress: progress)
    }

    /// True when the diarization model files are already on disk (no
    /// download needed). Checks FluidAudio's cache for a compiled model
    /// rather than a specific variant name, so it survives upstream
    /// renames.
    public static var modelIsCached: Bool {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/sortformer")
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return false }
        return files.contains { ($0 as? URL)?.pathExtension == "mlmodelc" }
    }

    // MARK: - Session

    public func start() async throws {
        let models = try await Self.sharedModels()
        diarizer.initialize(models: models)
    }

    /// Prime the diarizer with remembered voices, so their slots come back
    /// already named ("Igor") instead of positional ("Speaker 2").
    ///
    /// Must run after `start()` and before any real audio: enrollment resets
    /// the timeline, so priming mid-meeting would throw away the meeting.
    /// Enrollment is additive — a voice that fails to prime just means that
    /// person stays "Speaker N" for this meeting.
    public func enroll(_ voices: [(name: String, samples: [Float])]) {
        guard !voices.isEmpty else { return }
        queue.sync { [diarizer] in
            for voice in voices where !voice.samples.isEmpty {
                do {
                    _ = try diarizer.enrollSpeaker(withAudio: voice.samples,
                                                   named: voice.name)
                } catch {
                    NSLog("ODE: could not enroll voice '\(voice.name)': \(error.localizedDescription)")
                }
            }
        }
    }

    /// Feed one buffer of incoming-call audio (any format).
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let samples = convertTo16kMono(buffer), !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            _ = try? self.diarizer.process(samples: samples)
            self.retainAudioLocked(samples)
            self.topUpSnippetsLocked()
        }
    }

    /// Flush any buffered audio through the model.
    public func finish() {
        queue.sync { [diarizer] in
            _ = try? diarizer.process()
        }
    }

    /// Dominant speaker within [start, end] seconds of stream time — an
    /// enrolled name ("Igor") when the slot was primed with a remembered
    /// voice, otherwise "Speaker 2". Nil when no speaker activity is known.
    public func speakerLabel(from start: TimeInterval, to end: TimeInterval) -> String? {
        guard end > start else { return nil }
        return queue.sync {
            var best: (index: Int, overlap: Float)?
            for (index, speaker) in diarizer.timeline.speakers {
                var overlap: Float = 0
                for seg in speaker.finalizedSegments + speaker.tentativeSegments {
                    let s = max(Float(start), seg.startTime)
                    let e = min(Float(end), seg.endTime)
                    if e > s { overlap += e - s }
                }
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (index, overlap)
                }
            }
            guard let best else { return nil }
            return labelLocked(index: best.index)
        }
    }

    // MARK: - Voice snippets

    /// Recent audio kept so a speaker can be turned into a remembered voice
    /// after the meeting, when the user actually knows who was talking.
    /// Bounded: 30 s of 16 kHz mono is ~1.9 MB.
    private static let windowSeconds = 30.0
    private var window: [Float] = []
    /// Absolute sample index of `window[0]`.
    private var windowStart = 0
    /// Accumulated per-slot speech, and how far into the stream each slot
    /// has already been harvested (so audio is never copied twice).
    private var snippets: [Int: [Float]] = [:]
    private var harvested: [Int: Int] = [:]

    /// Voice samples gathered this meeting, keyed by the label the transcript
    /// uses. Already-enrolled speakers are excluded: ODE knows them, and
    /// re-saving a name from its own enrollment audio would compound drift.
    public func voiceSamples() -> [String: [Float]] {
        queue.sync {
            var out: [String: [Float]] = [:]
            for (index, samples) in snippets {
                guard diarizer.timeline.speakers[index]?.name == nil else { continue }
                guard Double(samples.count) / Self.feedFormat.sampleRate
                        >= VoiceProfileStore.minimumSeconds else { continue }
                out[labelLocked(index: index)] = samples
            }
            return out
        }
    }

    /// Label for a slot: its enrolled name, else the positional fallback.
    private func labelLocked(index: Int) -> String {
        if let name = diarizer.timeline.speakers[index]?.name, !name.isEmpty {
            return name
        }
        return "Speaker \(index + 1)"
    }

    /// Keep the newest audio, dropping the oldest past the window.
    private func retainAudioLocked(_ samples: [Float]) {
        window.append(contentsOf: samples)
        let cap = Int(Self.windowSeconds * Self.feedFormat.sampleRate)
        if window.count > cap {
            let drop = window.count - cap
            window.removeFirst(drop)
            windowStart += drop
        }
    }

    /// Copy each unnamed speaker's finalized speech out of the window until
    /// it has enough for enrollment. Only finalized segments are harvested —
    /// tentative ones can still be reassigned to a different speaker, and a
    /// snippet of the wrong person is worse than no snippet.
    private func topUpSnippetsLocked() {
        let rate = Self.feedFormat.sampleRate
        let target = Int(VoiceProfileStore.maximumSeconds * rate)
        let windowEnd = windowStart + window.count
        for (index, speaker) in diarizer.timeline.speakers {
            guard speaker.name == nil else { continue }
            var have = snippets[index] ?? []
            guard have.count < target else { continue }
            var from = harvested[index] ?? 0
            // Only segments past the harvest point can contribute. Filtering
            // first keeps the sort proportional to new speech rather than to
            // the whole meeting — this runs on every buffer, and
            // `finalizedSegments` grows all session.
            let pending = speaker.finalizedSegments.filter {
                Int(Double($0.endTime) * rate) > from
            }
            guard !pending.isEmpty else { continue }
            for seg in pending.sorted(by: { $0.startTime < $1.startTime }) {
                let s = max(Int(Double(seg.startTime) * rate), max(from, windowStart))
                let e = min(Int(Double(seg.endTime) * rate), windowEnd)
                guard e > s else { continue }
                have.append(contentsOf: window[(s - windowStart)..<(e - windowStart)])
                from = e
                if have.count >= target { break }
            }
            snippets[index] = have.count > target ? Array(have.prefix(target)) : have
            harvested[index] = from
        }
    }

    // MARK: - Conversion

    /// Convert to a fresh 16 kHz mono sample array (a copy the audio engine
    /// can't recycle from under us).
    private func convertTo16kMono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let fmt = Self.feedFormat
        if buffer.format == fmt, let ch = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: fmt)
        }
        guard let converter else { return nil }
        let ratio = fmt.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard out.frameLength > 0, let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}
