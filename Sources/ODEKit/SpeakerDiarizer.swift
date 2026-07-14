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

    // MARK: - Session

    public func start() async throws {
        let models = try await Self.sharedModels()
        diarizer.initialize(models: models)
    }

    /// Feed one buffer of incoming-call audio (any format).
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let samples = convertTo16kMono(buffer), !samples.isEmpty else { return }
        queue.async { [diarizer] in
            _ = try? diarizer.process(samples: samples)
        }
    }

    /// Flush any buffered audio through the model.
    public func finish() {
        queue.sync { [diarizer] in
            _ = try? diarizer.process()
        }
    }

    /// Dominant speaker within [start, end] seconds of stream time, e.g.
    /// "Speaker 2" — nil when no speaker activity is known for the interval.
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
            return "Speaker \(best.index + 1)"
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
