import Foundation
import AVFoundation

/// Coordinates a full meeting transcription: one transcriber for your mic
/// ("You") and one for the incoming audio ("Others"), merged into a single
/// timestamped transcript and saved when the meeting ends.
@available(macOS 26.0, *)
public final class MeetingTranscriber {
    private let you = StreamTranscriber()
    private let others = StreamTranscriber()
    private let lock = NSLock()
    private var segments: [TranscriptSegment] = []
    private var startedAt = Date()
    private var running = false

    public init() {}

    public static func ensureModel() async throws {
        try await StreamTranscriber.ensureModel()
    }

    /// Begin a session. Wire `feedMic`/`feedOthers` to the engine audio taps.
    public func start() async throws {
        startedAt = Date()
        lock.lock(); segments.removeAll(); running = true; lock.unlock()

        you.onSegment = { [weak self] seg in self?.add("You", seg) }
        others.onSegment = { [weak self] seg in self?.add("Others", seg) }
        try await you.start()
        try await others.start()
    }

    private func add(_ speaker: String, _ seg: StreamTranscriber.Segment) {
        let elapsedBase = Date().timeIntervalSince(startedAt)
        // The transcriber's times are relative to its own stream start, which is
        // the meeting start, so use them directly; fall back to wall-clock.
        let start = seg.start > 0 ? seg.start : elapsedBase
        lock.lock()
        segments.append(TranscriptSegment(speaker: speaker, start: start,
                                          end: max(seg.end, start), text: seg.text))
        lock.unlock()
    }

    public func feedMic(_ buffer: AVAudioPCMBuffer) {
        guard running else { return }
        you.append(buffer)
    }

    public func feedOthers(_ buffer: AVAudioPCMBuffer) {
        guard running else { return }
        others.append(buffer)
    }

    /// Finish, build, and persist the transcript. Returns it (or nil if empty).
    @discardableResult
    public func finishAndSave(title: String? = nil) async -> Transcript? {
        lock.lock(); running = false; lock.unlock()
        await you.finish()
        await others.finish()

        lock.lock(); let segs = segments; lock.unlock()
        guard !segs.isEmpty else { return nil }

        let ended = Date()
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        let autoTitle = title ?? "\(df.string(from: startedAt)) Meeting"
        let transcript = Transcript(title: autoTitle, startedAt: startedAt,
                                    endedAt: ended, segments: segs)
        TranscriptStore.shared.save(transcript)
        return transcript
    }
}
