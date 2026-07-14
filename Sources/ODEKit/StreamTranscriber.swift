import Foundation
import AVFoundation
import Speech

/// On-device live transcription of a single audio stream using the macOS 26
/// `SpeechAnalyzer` / `SpeechTranscriber` API. Feed it 48 kHz mono buffers; it
/// emits finalized, timestamped text segments via the `onSegment` callback.
///
/// One instance transcribes one stream (e.g. your mic, or the incoming audio),
/// so the caller can attach a speaker label to each.
@available(macOS 26.0, *)
public final class StreamTranscriber: SpeechTranscribing {
    /// A finalized chunk of recognized speech with timing relative to session start.
    public typealias Segment = SpeechSegment

    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    public var onSegment: ((Segment) -> Void)?

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Ensure the on-device model for `locale` is installed (downloads if needed).
    public static func ensureModel(for locale: Locale = .current) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw NSError(domain: "ode.transcribe", code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Locale \(locale.identifier) is not supported for transcription."])
        }
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            return
        }
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                      reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    }

    /// Begin a transcription session.
    public func start() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],            // finalized results only
            attributeOptions: [.audioTimeRange])
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputContinuation = continuation

        // Collect finalized segments.
        resultsTask = Task { [weak self] in
            guard let self, let transcriber = self.transcriber else { return }
            do {
                for try await result in transcriber.results where result.isFinal {
                    let attributed = result.text
                    let text = String(attributed.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    // Span from the first run's start to the last run's end.
                    var startT: TimeInterval = 0
                    var endT: TimeInterval = 0
                    var sawRange = false
                    for run in attributed.runs {
                        if let r = run.audioTimeRange {
                            if !sawRange { startT = r.start.seconds; sawRange = true }
                            endT = r.end.seconds
                        }
                    }
                    self.onSegment?(Segment(start: startT, end: max(endT, startT), text: text))
                }
            } catch {
                NSLog("ODE transcribe: results error \(error.localizedDescription)")
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// Feed one buffer of audio (any format; converted to the analyzer's format).
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = inputContinuation,
              let analyzerFormat else { return }

        let input: AVAudioPCMBuffer
        if buffer.format == analyzerFormat {
            input = buffer
        } else {
            if converter == nil || converter?.outputFormat != analyzerFormat {
                converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            }
            guard let converter else { return }
            let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: cap) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            input = out
        }
        continuation.yield(AnalyzerInput(buffer: input))
    }

    /// Finish the session and flush any pending audio.
    public func finish() async {
        inputContinuation?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        // Wait for the results stream to drain naturally (do NOT cancel — that
        // would drop the final segments we just flushed).
        await resultsTask?.value
        analyzer = nil
        transcriber = nil
        inputContinuation = nil
        resultsTask = nil
    }
}
