import AVFoundation
import FluidAudio

/// On-device live transcription using NVIDIA Parakeet TDT v3 (CoreML via
/// FluidAudio, running on the Apple Neural Engine).
///
/// Alternative to the macOS 26 SpeechAnalyzer engine: works on macOS 14+,
/// benchmarks stronger on conversational/disfluent speech (meetings) and on
/// Spanish, and offloads inference to the ANE so it doesn't compete with the
/// DPDFNet denoiser for CPU.
///
/// Feed it audio buffers of any format; it emits finalized text segments via
/// `onSegment`. Segments carry no engine timing (`start == 0`), so consumers
/// use their wall-clock fallback for ordering.
public final class ParakeetStreamTranscriber: SpeechTranscribing {
    public var onSegment: ((SpeechSegment) -> Void)?

    private var manager: SlidingWindowAsrManager?
    private var updatesTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var intake: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var converter: AVAudioConverter?

    /// Guards `emittedText`/`pendingRange`: confirmed-update handling and the
    /// final flush can race, and segments must never be emitted twice.
    private let emitLock = NSLock()
    private var emittedText = ""
    /// Stream-time span (seconds) of the last hypothesis — token timings are
    /// globalized to the full audio timeline by the sliding-window manager.
    /// When a hypothesis is confirmed, this span timestamps the emitted
    /// segment (needed for transcript ordering and speaker diarization).
    private var pendingRange: (start: TimeInterval, end: TimeInterval)?
    /// End of the last emitted segment: segments with no token timings anchor
    /// here so they still sort after their predecessor instead of falling
    /// back to (much later) wall-clock arrival time.
    private var lastEmittedEnd: TimeInterval = 0

    /// Parakeet consumes 16 kHz mono float.
    private static let feedFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
        channels: 1, interleaved: false)!

    public init() {}

    // MARK: - Shared model cache

    /// The CoreML weights are large, and the "You" and "Others" streams each
    /// run their own manager — download/compile once and share. Guarded by a
    /// lock (NOT an actor: the CLI blocks its main thread on a semaphore, and
    /// a @MainActor cache would deadlock there).
    private static let modelsLock = NSLock()
    private static var modelsTask: Task<AsrModels, Error>?

    private static func sharedModels(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AsrModels {
        modelsLock.lock()
        let task: Task<AsrModels, Error>
        if let existing = modelsTask {
            task = existing
        } else {
            task = Task {
                try await AsrModels.downloadAndLoad(progressHandler: { p in
                    progress?(p.fractionCompleted)
                })
            }
            modelsTask = task
        }
        modelsLock.unlock()
        do {
            return try await task.value
        } catch {
            // Allow a retry (e.g. download failed while offline).
            modelsLock.lock()
            modelsTask = nil
            modelsLock.unlock()
            throw error
        }
    }

    /// Ensure the Parakeet model is downloaded and loadable (~470 MB on first
    /// run, cached afterwards). `progress` reports download/compile progress
    /// in 0...1 on an unspecified queue.
    public static func ensureModel(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await sharedModels(progress: progress)
    }

    /// True when the model files are already on disk (no download needed).
    public static var modelIsCached: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory())
    }

    // MARK: - Session

    public func start() async throws {
        // Parakeet v3 auto-detects the spoken language (25 European languages,
        // Spanish included) — no per-locale configuration needed.
        let manager = SlidingWindowAsrManager(config: .streaming)
        try await manager.loadModels(Self.sharedModels())
        self.manager = manager
        resetEmitted()

        // Segments: whenever a window is confirmed, emit the newly confirmed
        // tail of the transcript. (Confirmed text is stable; volatile text may
        // still be revised, so it is only flushed at finish.) The confirmed
        // text is the *previous* hypothesis, so its timestamp span is the one
        // recorded before this update; the current update's span is stored
        // for the next confirmation.
        let updates = await manager.transcriptionUpdates
        updatesTask = Task { [weak self] in
            for await update in updates {
                guard let self, let manager = self.manager else { return }
                let span = Self.span(of: update.tokenTimings)
                if update.isConfirmed {
                    self.emitDelta(upTo: await manager.confirmedTranscript)
                }
                self.emitLock.lock()
                if let span { self.pendingRange = span }
                self.emitLock.unlock()
            }
        }

        // Feed through a single consumer task so buffer order is preserved
        // (spawning a Task per append would allow reordering).
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        intake = continuation
        feedTask = Task {
            for await buffer in stream {
                await manager.streamAudio(buffer)
            }
        }

        try await manager.startStreaming(source: .microphone)
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let intake else { return }
        // Convert to a fresh 16 kHz mono buffer: predictable input for the
        // recognizer, and a copy the audio engine can't recycle from under us.
        let fmt = Self.feedFormat
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: fmt)
        }
        guard let converter else { return }
        let ratio = fmt.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard out.frameLength > 0 else { return }
        intake.yield(out)
    }

    public func finish() async {
        intake?.finish()
        await feedTask?.value

        if let manager {
            // finish() returns the full transcript (confirmed + volatile
            // tail); emit whatever hasn't been emitted yet.
            if let final = try? await manager.finish(), !final.isEmpty {
                emitDelta(upTo: final)
            }
            await manager.cleanup()
        }

        updatesTask?.cancel()
        manager = nil
        intake = nil
        feedTask = nil
        updatesTask = nil
        converter = nil
    }

    // MARK: - Segment emission

    private func resetEmitted() {
        emitLock.lock()
        emittedText = ""
        pendingRange = nil
        lastEmittedEnd = 0
        emitLock.unlock()
    }

    private static func span(of timings: [TokenTiming]) -> (TimeInterval, TimeInterval)? {
        guard let first = timings.first, let last = timings.last else { return nil }
        return (first.startTime, max(last.endTime, first.startTime))
    }

    /// Emit whatever part of `text` (a cumulative transcript snapshot) hasn't
    /// been emitted yet. Reconciles by content, not by character counts: the
    /// manager's confirmed transcript and its `finish()` result are not always
    /// strict extensions of each other, so never re-emit text we've already
    /// sent and never drop text we haven't. (Internal for unit tests.)
    func emitDelta(upTo text: String) {
        emitLock.lock()
        let delta: String
        if text.hasPrefix(emittedText) {
            // Normal streaming case: the snapshot extends what we emitted.
            delta = String(text.dropFirst(emittedText.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            emittedText = text
        } else if emittedText.contains(text) {
            // Stale or duplicate snapshot — nothing new.
            delta = ""
        } else {
            // Disjoint snapshot (e.g. finish() returning only the volatile
            // tail): emit it whole so no speech is lost.
            delta = text.trimmingCharacters(in: .whitespacesAndNewlines)
            emittedText += (emittedText.isEmpty ? "" : " ") + text
        }
        // Timestamp: token-timing span when available; otherwise anchor just
        // after the previous segment so ordering stays correct. Never move
        // backwards — spans can overlap across sliding windows.
        let start: TimeInterval
        let end: TimeInterval
        if let range = pendingRange {
            start = max(range.start, lastEmittedEnd)
            end = max(range.end, start)
        } else {
            start = lastEmittedEnd
            end = lastEmittedEnd
        }
        if !delta.isEmpty { lastEmittedEnd = end }
        emitLock.unlock()

        guard !delta.isEmpty else { return }
        onSegment?(SpeechSegment(start: start, end: end, text: delta))
    }
}
