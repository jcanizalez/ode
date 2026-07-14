import Foundation
import AVFoundation

/// Coordinates a full meeting transcription: one transcriber for your mic
/// ("You") and one for the incoming audio ("Others"), merged into a single
/// timestamped transcript and saved when the meeting ends.
@available(macOS 26.0, *)
public final class MeetingTranscriber {
    private let you: any SpeechTranscribing
    private let others: any SpeechTranscribing
    private let lock = NSLock()
    private var segments: [TranscriptSegment] = []
    private var liveChat: [ChatMessage] = []
    private var startedAt = Date()
    private var running = false

    public init(engine: TranscriptionEngine = .apple) {
        switch engine {
        case .apple:
            you = StreamTranscriber()
            others = StreamTranscriber()
        case .parakeet:
            you = ParakeetStreamTranscriber()
            others = ParakeetStreamTranscriber()
        }
    }

    public static func ensureModel(engine: TranscriptionEngine = .apple) async throws {
        switch engine {
        case .apple: try await StreamTranscriber.ensureModel()
        case .parakeet: try await ParakeetStreamTranscriber.ensureModel()
        }
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

    private func add(_ speaker: String, _ seg: SpeechSegment) {
        let elapsedBase = Date().timeIntervalSince(startedAt)
        // The transcriber's times are relative to its own stream start, which is
        // the meeting start, so use them directly; fall back to wall-clock.
        let start = seg.start > 0 ? seg.start : elapsedBase
        lock.lock()
        segments.append(TranscriptSegment(speaker: speaker, start: start,
                                          end: max(seg.end, start), text: seg.text))
        lock.unlock()
    }

    /// Snapshot of the meeting *so far* (nil when idle or nothing was said
    /// yet). Lets the app show the transcript and answer questions about the
    /// meeting while it is still running.
    public func liveSnapshot() -> Transcript? {
        lock.lock()
        let segs = segments
        let isRunning = running
        let chat = liveChat
        lock.unlock()
        guard isRunning, !segs.isEmpty else { return nil }
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        return Transcript(title: "\(df.string(from: startedAt)) Meeting",
                          startedAt: startedAt, endedAt: Date(),
                          segments: segs, chat: chat)
    }

    /// Record a Q&A exchange asked during the live meeting, so it's part of
    /// the transcript when the meeting is saved.
    public func recordChat(question: String, answer: String) {
        lock.lock()
        liveChat.append(ChatMessage(question: question, answer: answer))
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

        lock.lock(); let segs = segments; let chat = liveChat; lock.unlock()
        guard !segs.isEmpty else { return nil }

        let ended = Date()
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        let autoTitle = title ?? "\(df.string(from: startedAt)) Meeting"
        let transcript = Transcript(title: autoTitle, startedAt: startedAt,
                                    endedAt: ended, segments: segs, chat: chat)
        TranscriptStore.shared.save(transcript)
        return transcript
    }
}
