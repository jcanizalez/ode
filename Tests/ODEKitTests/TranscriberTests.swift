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

final class MeetingNotesFormatTests: XCTestCase {
    private func transcript(lines: Int, lineText: String,
                            alternate: Bool = true) -> Transcript {
        var segs: [TranscriptSegment] = []
        for i in 0..<lines {
            let speaker: String = alternate
                ? ((i % 2 == 0) ? "You" : "Others") : "You"
            let start = TimeInterval(i) * 10
            segs.append(TranscriptSegment(speaker: speaker, start: start,
                                          end: start + 5, text: "\(lineText) \(i)"))
        }
        return Transcript(title: "T", startedAt: Date(), endedAt: Date(), segments: segs)
    }

    func testTimestampedTextFormat() {
        let t = transcript(lines: 3, lineText: "hola")
        let text = MeetingNotesFormat.timestampedText(t)
        XCTAssertTrue(text.hasPrefix("[00:00] You: hola 0"))
        XCTAssertTrue(text.contains("[00:10] Others: hola 1"))
        XCTAssertEqual(text.split(separator: "\n").count, 3)
    }

    func testYouNameInjection() {
        let t = transcript(lines: 2, lineText: "hola")
        let text = MeetingNotesFormat.timestampedText(t, youName: "Javier")
        // "You" becomes "Javier (me)" for the model; other speakers untouched.
        XCTAssertTrue(text.contains("[00:00] Javier (me): hola 0"))
        XCTAssertTrue(text.contains("[00:10] Others: hola 1"))
        // Without a name, the raw label stays.
        XCTAssertTrue(MeetingNotesFormat.timestampedText(t).contains("[00:00] You:"))
    }

    func testHasSubstanceGate() {
        let tiny = transcript(lines: 1, lineText: "hola")
        XCTAssertFalse(MeetingNotesFormat.hasSubstance(tiny))
        let real = transcript(lines: 40, lineText: "una frase con contenido suficiente")
        XCTAssertTrue(MeetingNotesFormat.hasSubstance(real))
    }

    func testConsecutiveSameSpeakerLinesMerge() {
        let t = transcript(lines: 4, lineText: "hola", alternate: false)
        let text = MeetingNotesFormat.timestampedText(t)
        // All four segments are "You" → one merged line, first timestamp kept.
        XCTAssertEqual(text.split(separator: "\n").count, 1)
        XCTAssertTrue(text.hasPrefix("[00:00] You: hola 0 hola 1"))
    }

    func testJustOverBudgetTerminates() {
        // Regression: text slightly over budget with few lines made the
        // downsampling step exceed the line count — the filter dropped
        // nothing and the loop spun forever (hung a real meeting's notes).
        var segs: [TranscriptSegment] = []
        for i in 0..<24 {   // ~24 lines × ~350 chars ≈ just over 8000
            let text = String(repeating: "palabra ", count: 43)
            segs.append(TranscriptSegment(speaker: i % 2 == 0 ? "You" : "Others",
                                          start: TimeInterval(i) * 30,
                                          end: TimeInterval(i) * 30 + 20, text: text))
        }
        let t = Transcript(title: "T", startedAt: Date(), endedAt: Date(), segments: segs)
        let out = MeetingNotesFormat.timestampedText(t, maxChars: 8_000)  // must return
        XCTAssertLessThanOrEqual(out.count, 8_000)
    }

    func testLongMonologueRespectsBudget() {
        // One speaker talking for 20 minutes: merged lines must stay capped
        // and the final render must never exceed the budget (a giant merged
        // monologue previously blew past it and hung the model).
        let t = transcript(lines: 120,
                           lineText: "sigo hablando sin parar sobre el mismo tema del proyecto",
                           alternate: false)
        let text = MeetingNotesFormat.timestampedText(t, maxChars: 8_000)
        XCTAssertLessThanOrEqual(text.count, 8_000)
        // Capped merging keeps periodic timestamps for the chapters call.
        XCTAssertGreaterThan(text.split(separator: "\n").count, 5)
    }

    func testDownsamplingPreservesTimeCoverage() {
        let t = transcript(lines: 200, lineText: "una frase bastante larga para forzar el recorte del texto")
        let text = MeetingNotesFormat.timestampedText(t, maxChars: 2_000)
        XCTAssertLessThan(text.count, 3_000)
        // Early AND late content survive (uniform sampling, not tail-truncation).
        XCTAssertTrue(text.contains("[00:"))
        XCTAssertTrue(text.contains("[3") || text.contains("[2"))  // ≥20 min marks
    }

    func testParseTimestamp() {
        XCTAssertEqual(MeetingNotesFormat.parseTimestamp("03:32"), 212)
        XCTAssertEqual(MeetingNotesFormat.parseTimestamp("1:02:03"), 3_723)
        XCTAssertEqual(MeetingNotesFormat.parseTimestamp(" 00:05 "), 5)
        XCTAssertNil(MeetingNotesFormat.parseTimestamp("3m20s"))
        XCTAssertNil(MeetingNotesFormat.parseTimestamp(""))
        XCTAssertNil(MeetingNotesFormat.parseTimestamp("::"))
    }

    func testCleanChaptersValidatesSortsAndDedups() {
        let chapters = MeetingNotesFormat.cleanChapters([
            ("Cierre", "20:00", []),
            ("Apertura", "00:05", ["hola"]),
            ("Basura", "nope", []),
            ("Fuera de rango", "99:00", []),
            ("Duplicado", "00:05", []),
        ], duration: 1_500)
        XCTAssertEqual(chapters.map(\.title), ["Apertura", "Cierre"])
        XCTAssertEqual(chapters[0].startSeconds, 5)
        XCTAssertEqual(chapters[0].bullets, ["hola"])
    }

    func testFallbackParser() {
        let raw = """
        SUMMARY: Se revisó el proyecto de pagos.
        POINT: Integración lista en pruebas
        DECISION: Demo la próxima semana
        OPEN: ¿Quién revisa los logs?
        ACTION: Corregir mensaje de tarjeta | Speaker 1
        ACTION: Enviar minuta | none
        CHAPTER: 00:10 | Apertura | saludo; agenda
        garbage line without tag
        """
        let n = MeetingNotesFormat.parseFallback(raw)
        XCTAssertEqual(n.summary, "Se revisó el proyecto de pagos.")
        XCTAssertEqual(n.keyPoints, ["Integración lista en pruebas"])
        XCTAssertEqual(n.decisions, ["Demo la próxima semana"])
        XCTAssertEqual(n.openQuestions, ["¿Quién revisa los logs?"])
        XCTAssertEqual(n.actionItems.count, 2)
        XCTAssertEqual(n.actionItems[0].owner, "Speaker 1")
        XCTAssertNil(n.actionItems[1].owner)
        XCTAssertEqual(n.chapters.count, 1)
        XCTAssertEqual(n.chapters[0].bullets, ["saludo", "agenda"])
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
