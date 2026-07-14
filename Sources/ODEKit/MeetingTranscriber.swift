import Foundation
import AVFoundation

/// Coordinates a full meeting transcription: one transcriber for your mic
/// ("You") and one for the incoming audio ("Others"), merged into a single
/// timestamped transcript and saved when the meeting ends.
@available(macOS 26.0, *)
public final class MeetingTranscriber {
    private let you: any SpeechTranscribing
    private let others: any SpeechTranscribing
    private let diarizer: SpeakerDiarizer?
    private let lock = NSLock()
    private var segments: [TranscriptSegment] = []
    private var liveChat: [ChatMessage] = []
    private var startedAt = Date()
    private var running = false

    // Meeting context, set by the controller around start():
    /// Calendar event title, when one was found ("Sprint Planning").
    public var suggestedTitle: String?
    /// Attendee first names from the calendar event.
    public var attendees: [String]?
    /// Conferencing app detected at meeting start ("Zoom", "Microsoft Teams").
    public var sourceApp: String?

    public init(engine: TranscriptionEngine = .apple, detectSpeakers: Bool = false) {
        switch engine {
        case .apple:
            you = StreamTranscriber()
            others = StreamTranscriber()
        case .parakeet:
            you = ParakeetStreamTranscriber()
            others = ParakeetStreamTranscriber()
        }
        // Diarize the incoming audio to sub-label "Others" as "Speaker 1/2/…".
        diarizer = detectSpeakers ? SpeakerDiarizer() : nil
    }

    public static func ensureModel(engine: TranscriptionEngine = .apple,
                                   detectSpeakers: Bool = false) async throws {
        switch engine {
        case .apple: try await StreamTranscriber.ensureModel()
        case .parakeet: try await ParakeetStreamTranscriber.ensureModel()
        }
        if detectSpeakers { try await SpeakerDiarizer.ensureModel() }
    }

    /// Begin a session. Wire `feedMic`/`feedOthers` to the engine audio taps.
    public func start() async throws {
        startedAt = Date()
        lock.lock(); segments.removeAll(); running = true; lock.unlock()

        you.onSegment = { [weak self] seg in self?.add("You", seg) }
        others.onSegment = { [weak self] seg in self?.add("Others", seg) }
        try await you.start()
        try await others.start()
        // Diarization is additive — if its model fails to load, the meeting
        // still transcribes with plain "Others" labels.
        if let diarizer {
            do { try await diarizer.start() } catch {
                NSLog("ODE: speaker detection unavailable: \(error.localizedDescription)")
            }
        }
    }

    private func add(_ speaker: String, _ seg: SpeechSegment) {
        let elapsedBase = Date().timeIntervalSince(startedAt)
        // The transcriber's times are relative to its own stream start, which is
        // the meeting start, so use them directly; fall back to wall-clock.
        let start = seg.start > 0 ? seg.start : elapsedBase
        let end = max(seg.end, start)
        // Sub-label remote speech with the dominant diarized speaker. Timed
        // segments query their exact span; untimed ones (anchored after their
        // predecessor) query a window around the anchor so end-of-meeting
        // stragglers still get labeled instead of staying "Others".
        var speaker = speaker
        if speaker == "Others", let diarizer {
            let qs = seg.end > seg.start ? seg.start : max(0, start - 10)
            let qe = seg.end > seg.start ? seg.end : start + 2
            if let label = diarizer.speakerLabel(from: qs, to: qe) {
                speaker = label
            }
        }
        lock.lock()
        segments.append(TranscriptSegment(speaker: speaker, start: start,
                                          end: end, text: seg.text))
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
        return Transcript(title: suggestedTitle ?? "\(df.string(from: startedAt)) Meeting",
                          startedAt: startedAt, endedAt: Date(),
                          segments: segs, sourceApp: sourceApp,
                          attendees: attendees, chat: chat)
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
        diarizer?.append(buffer)
    }

    /// Finish, build, and persist the transcript. Returns it (or nil if empty).
    @discardableResult
    public func finishAndSave(title: String? = nil) async -> Transcript? {
        lock.lock(); running = false; lock.unlock()
        await you.finish()
        await others.finish()
        diarizer?.finish()

        lock.lock(); let segs = segments; let chat = liveChat; lock.unlock()
        guard !segs.isEmpty else { return nil }

        let ended = Date()
        // Title priority: explicit → calendar event → AI (from the content)
        // → time-based.
        var autoTitle = title ?? suggestedTitle
        if autoTitle == nil {
            autoTitle = await MeetingAI.title(forSegments: segs)
        }
        let df = DateFormatter(); df.dateFormat = "h:mm a"
        let transcript = Transcript(title: autoTitle ?? "\(df.string(from: startedAt)) Meeting",
                                    startedAt: startedAt, endedAt: ended,
                                    segments: segs, sourceApp: sourceApp,
                                    attendees: attendees, chat: chat)
        TranscriptStore.shared.save(transcript)
        return transcript
    }
}
