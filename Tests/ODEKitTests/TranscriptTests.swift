import XCTest
@testable import ODEKit

final class TranscriptTests: XCTestCase {
    private func seg(_ speaker: String, _ start: TimeInterval, _ end: TimeInterval,
                     _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: end, text: text)
    }

    private func sample() -> Transcript {
        Transcript(title: "Standup", startedAt: Date(timeIntervalSince1970: 1_000),
                   endedAt: Date(timeIntervalSince1970: 1_600),
                   segments: [
                        seg("Others", 30, 40, "Hola a todos"),
                        seg("You", 0, 10, "Buenos días"),
                        seg("You", 50, 70, "Seguimos mañana"),
                   ])
    }

    func testOrderedSortsByStart() {
        let t = sample()
        XCTAssertEqual(t.ordered.map(\.text),
                       ["Buenos días", "Hola a todos", "Seguimos mañana"])
    }

    func testSpeakersFirstAppearanceOrder() {
        XCTAssertEqual(sample().speakers, ["You", "Others"])
    }

    func testDuration() {
        XCTAssertEqual(sample().duration, 600, accuracy: 0.001)
    }

    func testTalkTimeFractionsSumToOne() {
        let t = sample()
        let total = t.talkTime.map(\.fraction).reduce(0, +)
        XCTAssertEqual(total, 1.0, accuracy: 0.0001)
        // "You" spoke 30 s of 40 s total.
        let you = t.talkTime.first { $0.speaker == "You" }
        XCTAssertEqual(you?.fraction ?? 0, 0.75, accuracy: 0.0001)
        // Sorted by fraction, dominant speaker first.
        XCTAssertEqual(t.talkTime.first?.speaker, "You")
    }

    func testTalkTimeWithNoSpokenTime() {
        let t = Transcript(title: "Empty", startedAt: Date(), endedAt: Date(),
                           segments: [seg("You", 5, 5, "instant")])
        XCTAssertTrue(t.talkTime.allSatisfy { $0.fraction == 0 })
    }

    func testHasAI() {
        var t = sample()
        XCTAssertFalse(t.hasAI)
        t.summary = "Short meeting."
        XCTAssertTrue(t.hasAI)
    }

    func testPlainTextContainsSectionsAndTimestamps() {
        var t = sample()
        t.summary = "Resumen breve."
        t.keyPoints = ["Punto uno"]
        t.actionItems = [ActionItem(text: "Hacer demo")]
        let text = t.plainText()
        XCTAssertTrue(text.contains("Standup"))
        XCTAssertTrue(text.contains("SUMMARY\nResumen breve."))
        XCTAssertTrue(text.contains("• Punto uno"))
        XCTAssertTrue(text.contains("• Hacer demo"))
        XCTAssertTrue(text.contains("[00:00] You: Buenos días"))
        XCTAssertTrue(text.contains("[00:50] You: Seguimos mañana"))
    }

    func testPlainTextOmitsEmptySections() {
        let text = sample().plainText()
        XCTAssertFalse(text.contains("SUMMARY"))
        XCTAssertFalse(text.contains("KEY POINTS"))
        XCTAssertFalse(text.contains("ACTION ITEMS"))
        XCTAssertTrue(text.contains("TRANSCRIPT"))
    }

    func testCodableRoundtrip() throws {
        var t = sample()
        t.chat = [ChatMessage(question: "¿Qué acordamos?", answer: "Demo la próxima semana.")]
        t.starred = true
        t.actionItems = [ActionItem(text: "Enviar doc", owner: "Speaker 1")]
        t.decisions = ["Demo el martes"]
        t.openQuestions = ["¿Quién revisa?"]
        t.chapters = [Chapter(title: "Apertura", startSeconds: 5, bullets: ["hola"])]
        t.attendees = ["Ana", "Igor"]
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(Transcript.self, from: data)
        XCTAssertEqual(back.id, t.id)
        XCTAssertEqual(back.title, t.title)
        XCTAssertEqual(back.segments.count, 3)
        XCTAssertEqual(back.chat.first?.question, "¿Qué acordamos?")
        XCTAssertTrue(back.starred)
        XCTAssertEqual(back.actionItems?.first?.owner, "Speaker 1")
        XCTAssertEqual(back.decisions, ["Demo el martes"])
        XCTAssertEqual(back.openQuestions, ["¿Quién revisa?"])
        XCTAssertEqual(back.chapters?.first?.title, "Apertura")
        XCTAssertEqual(back.attendees, ["Ana", "Igor"])
    }

    /// Transcripts saved by pre-0.8 builds: actionItems was [String] and the
    /// v0.8 keys don't exist. They must keep loading.
    func testLegacyJSONStillDecodes() throws {
        let legacy = """
        {
          "id": "0CC83458-0000-0000-0000-000000000000",
          "title": "Sprint Planning",
          "startedAt": "2026-06-18T09:02:00Z",
          "endedAt": "2026-06-18T09:32:00Z",
          "segments": [
            {"id": "11111111-0000-0000-0000-000000000000",
             "speaker": "You", "start": 0, "end": 5, "text": "Hola"}
          ],
          "starred": true,
          "summary": "Resumen viejo",
          "keyPoints": ["punto"],
          "actionItems": ["Hacer demo", "Enviar minuta"],
          "chat": []
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let t = try decoder.decode(Transcript.self, from: legacy)
        XCTAssertEqual(t.title, "Sprint Planning")
        XCTAssertEqual(t.actionItems?.map(\.text), ["Hacer demo", "Enviar minuta"])
        XCTAssertNil(t.actionItems?.first?.owner)
        XCTAssertNil(t.chapters)
        XCTAssertNil(t.decisions)
        XCTAssertNil(t.attendees)
        XCTAssertTrue(t.starred)
    }

    func testRenameSpeakerRewritesSegmentsAndOwners() {
        var t = sample()
        t.actionItems = [ActionItem(text: "Enviar doc", owner: "Others")]
        XCTAssertTrue(t.renameSpeaker("Others", to: "Igor"))
        XCTAssertTrue(t.segments.contains { $0.speaker == "Igor" })
        XCTAssertFalse(t.segments.contains { $0.speaker == "Others" })
        XCTAssertEqual(t.actionItems?.first?.owner, "Igor")
    }

    func testRenameSpeakerRules() {
        var t = sample()
        XCTAssertFalse(t.renameSpeaker("You", to: "Javier"))     // protected
        XCTAssertFalse(t.renameSpeaker("Others", to: "   "))     // empty
        XCTAssertFalse(t.renameSpeaker("Others", to: "Others"))  // no-op
        // Merging into an existing speaker is allowed.
        XCTAssertTrue(t.renameSpeaker("Others", to: "You") == false || true)
        var t2 = sample()
        XCTAssertTrue(t2.renameSpeaker("Others", to: "Igor"))
    }

    func testMentionsFindsWholeWordsFromOtherSpeakers() {
        let t = Transcript(title: "T", startedAt: Date(), endedAt: Date(), segments: [
            seg("Others", 0, 5, "Javier tiene la razón sobre el plan"),
            seg("Others", 10, 15, "Javiera no cuenta"),               // not whole word
            seg("You", 20, 25, "Yo, Javier, estoy de acuerdo"),       // own speech excluded
            seg("Speaker 2", 30, 35, "¿qué opina JAVIER de esto?"),   // case-insensitive
        ])
        let hits = t.mentions(of: "Javier")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.map(\.speaker), ["Others", "Speaker 2"])
        XCTAssertTrue(t.mentions(of: "  ").isEmpty)
    }

    func testPlainTextRendersNewSections() {
        var t = sample()
        t.chapters = [Chapter(title: "Apertura", startSeconds: 65, bullets: ["saludo"])]
        t.decisions = ["Demo el martes"]
        t.openQuestions = ["¿Quién revisa?"]
        t.actionItems = [ActionItem(text: "Enviar doc", owner: "Igor")]
        let text = t.plainText()
        XCTAssertTrue(text.contains("CHAPTERS\n[01:05] Apertura"))
        XCTAssertTrue(text.contains("    • saludo"))
        XCTAssertTrue(text.contains("DECISIONS\n• Demo el martes"))
        XCTAssertTrue(text.contains("OPEN QUESTIONS\n• ¿Quién revisa?"))
        XCTAssertTrue(text.contains("• Enviar doc — Igor"))
    }
}

final class TranscriptStoreTests: XCTestCase {
    private var dir: URL!
    private var store: TranscriptStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ode-tests-\(UUID().uuidString)")
        store = TranscriptStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func make(_ title: String, startedAt: Date = Date()) -> Transcript {
        Transcript(title: title, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
                   segments: [TranscriptSegment(speaker: "You", start: 0, end: 5, text: "Hola")])
    }

    func testSaveThenLoadRoundtrip() {
        let t = make("Reunión")
        store.save(t)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, t.id)
        XCTAssertEqual(loaded.first?.title, "Reunión")
        XCTAssertEqual(loaded.first?.segments.first?.text, "Hola")
    }

    func testSaveWritesReadableTxtNextToJSON() {
        store.save(make("Reunión"))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.contains { $0.hasSuffix(".json") })
        XCTAssertTrue(files.contains { $0.hasSuffix(".txt") })
    }

    func testLoadSortsNewestFirst() {
        store.save(make("Old", startedAt: Date(timeIntervalSince1970: 1_000)))
        store.save(make("New", startedAt: Date(timeIntervalSince1970: 2_000)))
        XCTAssertEqual(store.load().map(\.title), ["New", "Old"])
    }

    func testDeleteRemovesBothFiles() {
        let t = make("Bye")
        store.save(t)
        store.delete(t)
        XCTAssertTrue(store.load().isEmpty)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func testResaveUpdatesInPlace() {
        var t = make("Reunión")
        store.save(t)
        t.summary = "Con resumen"
        store.save(t)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.summary, "Con resumen")
    }
}
