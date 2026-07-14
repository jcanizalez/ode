import XCTest
import AVFoundation
@testable import ODEKit

final class SpeechTypesTests: XCTestCase {
    func testSpeechSegmentInit() {
        let seg = SpeechSegment(start: 1.5, end: 3.0, text: "hola")
        XCTAssertEqual(seg.start, 1.5)
        XCTAssertEqual(seg.end, 3.0)
        XCTAssertEqual(seg.text, "hola")
    }

    func testTranscriptionEngineCases() {
        XCTAssertEqual(TranscriptionEngine.allCases, [.apple, .parakeet])
        XCTAssertEqual(TranscriptionEngine.apple.displayName, "Apple")
        XCTAssertEqual(TranscriptionEngine.parakeet.displayName, "Parakeet")
        XCTAssertEqual(TranscriptionEngine(rawValue: "parakeet"), .parakeet)
        XCTAssertNil(TranscriptionEngine(rawValue: "whisper"))
    }
}

/// Tests the confirmed-text reconciliation that turns cumulative transcript
/// snapshots into non-overlapping segments (the trickiest logic in the
/// Parakeet integration — see the scrambled-order bug it guards against).
final class ParakeetDeltaTests: XCTestCase {
    private func collect(_ body: (ParakeetStreamTranscriber) -> Void) -> [String] {
        let t = ParakeetStreamTranscriber()
        var segments: [String] = []
        t.onSegment = { segments.append($0.text) }
        body(t)
        return segments
    }

    func testFirstSnapshotEmitsWhole() {
        let segs = collect { $0.emitDelta(upTo: "hola mundo") }
        XCTAssertEqual(segs, ["hola mundo"])
    }

    func testExtensionEmitsOnlyTheNewSuffix() {
        let segs = collect {
            $0.emitDelta(upTo: "hola mundo")
            $0.emitDelta(upTo: "hola mundo amigos míos")
        }
        XCTAssertEqual(segs, ["hola mundo", "amigos míos"])
    }

    func testDuplicateSnapshotEmitsNothing() {
        let segs = collect {
            $0.emitDelta(upTo: "hola mundo")
            $0.emitDelta(upTo: "hola mundo")
        }
        XCTAssertEqual(segs, ["hola mundo"])
    }

    func testStaleSubsetEmitsNothing() {
        let segs = collect {
            $0.emitDelta(upTo: "hola mundo amigos")
            $0.emitDelta(upTo: "hola mundo")   // older snapshot arrives late
        }
        XCTAssertEqual(segs, ["hola mundo amigos"])
    }

    func testDisjointTailIsEmittedWhole() {
        // finish() can return only the volatile tail, unrelated by prefix.
        let segs = collect {
            $0.emitDelta(upTo: "hola mundo")
            $0.emitDelta(upTo: "una pregunta antes de continuar?")
        }
        XCTAssertEqual(segs, ["hola mundo", "una pregunta antes de continuar?"])
    }

    func testEmptyOrWhitespaceDeltaIsDropped() {
        let segs = collect {
            $0.emitDelta(upTo: "hola")
            $0.emitDelta(upTo: "hola   ")
        }
        XCTAssertEqual(segs, ["hola"])
    }

    func testLifecycleSafeBeforeStart() async {
        let t = ParakeetStreamTranscriber()
        // Feeding and finishing an unstarted transcriber must be no-ops.
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 480)!
        buf.frameLength = 480
        t.append(buf)
        await t.finish()
        _ = ParakeetStreamTranscriber.modelIsCached  // just exercises the path
    }
}

final class SpeakerDiarizerTests: XCTestCase {
    func testSpeakerLabelNilWithoutAudio() {
        guard #available(macOS 14.0, *) else { return }
        let d = SpeakerDiarizer()
        XCTAssertNil(d.speakerLabel(from: 0, to: 10))
    }

    func testSpeakerLabelNilForInvertedInterval() {
        guard #available(macOS 14.0, *) else { return }
        let d = SpeakerDiarizer()
        XCTAssertNil(d.speakerLabel(from: 5, to: 2))
    }

    func testAppendWithoutModelDoesNotCrash() {
        guard #available(macOS 14.0, *) else { return }
        let d = SpeakerDiarizer()
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4_800)!
        buf.frameLength = 4_800
        d.append(buf)
        d.finish()
    }
}

final class MeetingTranscriberTests: XCTestCase {
    func testLiveSnapshotNilBeforeStart() {
        guard #available(macOS 26.0, *) else { return }
        let mt = MeetingTranscriber(engine: .parakeet)
        XCTAssertNil(mt.liveSnapshot())
    }

    func testFeedBeforeStartIsIgnored() {
        guard #available(macOS 26.0, *) else { return }
        let mt = MeetingTranscriber(engine: .parakeet, detectSpeakers: true)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 480)!
        buf.frameLength = 480
        mt.feedMic(buf)
        mt.feedOthers(buf)
        XCTAssertNil(mt.liveSnapshot())
    }

    func testFinishWithoutSegmentsReturnsNil() async {
        guard #available(macOS 26.0, *) else { return }
        let mt = MeetingTranscriber(engine: .parakeet)
        mt.recordChat(question: "¿algo?", answer: "nada")
        let saved = await mt.finishAndSave()
        XCTAssertNil(saved)
    }
}

final class MeetingAITests: XCTestCase {
    private func transcript(lines: Int, lineText: String) -> Transcript {
        var segs: [TranscriptSegment] = []
        for i in 0..<lines {
            let speaker: String = (i % 2 == 0) ? "You" : "Others"
            let start = TimeInterval(i) * 10
            let end = start + 5
            let text = "\(lineText) \(i)"
            segs.append(TranscriptSegment(speaker: speaker, start: start, end: end, text: text))
        }
        return Transcript(title: "T", startedAt: Date(), endedAt: Date(), segments: segs)
    }

    func testTranscriptTextShortIsUntouched() {
        guard #available(macOS 26.0, *) else { return }
        let t = transcript(lines: 3, lineText: "hola")
        let text = MeetingAI.transcriptText(t)
        XCTAssertTrue(text.hasPrefix("You: hola 0"))
        XCTAssertFalse(text.contains("omitted"))
        XCTAssertEqual(text.split(separator: "\n").count, 3)
    }

    func testTranscriptTextLongKeepsRecentTail() {
        guard #available(macOS 26.0, *) else { return }
        let t = transcript(lines: 50, lineText: "una frase bastante larga para forzar el corte")
        let text = MeetingAI.transcriptText(t, maxChars: 500)
        XCTAssertTrue(text.hasPrefix("[Earlier part of the meeting omitted]"))
        XCTAssertTrue(text.contains("49"))            // most recent line survives
        XCTAssertFalse(text.contains("larga para forzar el corte 0\n")) // oldest dropped
        XCTAssertLessThan(text.count, 600)
        // Truncation lands on a line boundary: first content line is complete.
        let firstContentLine = text.split(separator: "\n").dropFirst().first ?? ""
        XCTAssertTrue(firstContentLine.hasPrefix("You:") || firstContentLine.hasPrefix("Others:"))
    }
}

final class AudioDevicesTests: XCTestCase {
    /// CI runners may expose no audio hardware; device-presence assertions
    /// only hold on a real Mac.
    private var onCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }

    func testEnumeratesAtLeastOneDevice() throws {
        try XCTSkipIf(onCI, "no audio hardware on CI runners")
        XCTAssertFalse(AudioDevices.all().isEmpty)
    }

    func testDefaultDevicesResolve() throws {
        try XCTSkipIf(onCI, "no audio hardware on CI runners")
        // Any Mac running the tests has a default output.
        let out = AudioDevices.defaultOutput()
        XCTAssertNotNil(out)
        XCTAssertTrue(out?.hasOutput ?? false)
    }

    func testFindByBogusUIDReturnsNil() {
        XCTAssertNil(AudioDevices.findByUID("definitely-not-a-real-uid"))
    }

    func testFindByNameMatchesCaseInsensitively() {
        guard let any = AudioDevices.all().first else { return }
        XCTAssertEqual(AudioDevices.find(name: any.name.lowercased())?.name, any.name)
    }
}
