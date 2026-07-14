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
        t.actionItems = ["Hacer demo"]
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
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(Transcript.self, from: data)
        XCTAssertEqual(back.id, t.id)
        XCTAssertEqual(back.title, t.title)
        XCTAssertEqual(back.segments.count, 3)
        XCTAssertEqual(back.chat.first?.question, "¿Qué acordamos?")
        XCTAssertTrue(back.starred)
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
