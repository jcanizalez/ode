import AVFoundation

/// A finalized chunk of recognized speech with timing relative to session
/// start. `start == 0` means the engine provided no timing — consumers fall
/// back to wall-clock elapsed time.
public struct SpeechSegment {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// One live speech-to-text stream. ODE has two implementations:
///  • `StreamTranscriber`         — Apple SpeechAnalyzer (macOS 26+)
///  • `ParakeetStreamTranscriber` — NVIDIA Parakeet TDT v3 via FluidAudio
/// One instance transcribes one stream (your mic, or the incoming audio), so
/// the caller can attach a speaker label to each.
public protocol SpeechTranscribing: AnyObject {
    /// Called with each finalized segment (arbitrary thread).
    var onSegment: ((SpeechSegment) -> Void)? { get set }
    /// Begin the session.
    func start() async throws
    /// Feed one buffer of audio (any format).
    func append(_ buffer: AVAudioPCMBuffer)
    /// Finish the session and flush pending audio/segments.
    func finish() async
}

/// Which speech-to-text engine to use for meeting transcription.
public enum TranscriptionEngine: String, CaseIterable, Sendable {
    /// Apple SpeechAnalyzer — built-in, macOS 26+, best on clean speech.
    case apple
    /// NVIDIA Parakeet TDT v3 (CoreML on the Neural Engine) — stronger on
    /// conversational/disfluent speech and Spanish; ~600 MB model download.
    case parakeet

    public var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .parakeet: return "Parakeet"
        }
    }
}
