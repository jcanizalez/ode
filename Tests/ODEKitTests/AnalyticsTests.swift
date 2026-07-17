import XCTest
@testable import ODEKit

final class SpeakingAnalyticsTests: XCTestCase {
    private func seg(_ speaker: String, _ start: TimeInterval, _ end: TimeInterval,
                     _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: end, text: text)
    }

    private func transcript(_ segments: [TranscriptSegment]) -> Transcript {
        Transcript(title: "Test", startedAt: Date(timeIntervalSince1970: 0),
                   endedAt: Date(timeIntervalSince1970: 600), segments: segments)
    }

    func testWordsPerMinuteUsesSpeakingTime() {
        // 30 words in 12 seconds of speech → 150 WPM, regardless of the
        // 10-minute wall clock.
        let words = Array(repeating: "word", count: 30).joined(separator: " ")
        let a = SpeakingAnalytics.compute(for: transcript([
            seg("You", 0, 12, words),
        ]))
        XCTAssertEqual(a.perSpeaker.first?.wordsPerMinute ?? 0, 150, accuracy: 0.1)
        XCTAssertEqual(a.meetingWPM, 150, accuracy: 0.1)
        XCTAssertEqual(a.totalWords, 30)
    }

    func testFillerWordBoundaries() {
        // "likely" and "unlike" must not count as "like"; "Um," must count
        // despite punctuation and capitalization.
        let count = SpeakingAnalytics.countFillers(
            in: "Um, that is likely fine. I like it, unlike before. Like really.",
            list: SpeakingAnalytics.fillers["en"]!)
        XCTAssertEqual(count, 3)  // "Um", "like", "Like"
    }

    func testMultiWordFillersConsumeTheirWords() {
        // "you know" is ONE filler, and its "know" can't be re-matched.
        let count = SpeakingAnalytics.countFillers(
            in: "you know, it's basically done, you know",
            list: SpeakingAnalytics.fillers["en"]!)
        XCTAssertEqual(count, 3)  // 2× "you know" + "basically"
    }

    func testSpanishFillersAndLanguagePick() {
        let segments = [
            seg("You", 0, 10, "Bueno, este proyecto está casi listo, ¿no?"),
            seg("You", 11, 20, "O sea, pues faltan un par de detalles nada más."),
        ]
        XCTAssertEqual(SpeakingAnalytics.dominantLanguage(of: segments), "es")
        let a = SpeakingAnalytics.compute(for: transcript(segments))
        // "Bueno", "¿no?", "O sea", "pues" — "este" here is a real
        // demonstrative but the list can't know that; it also counts.
        XCTAssertGreaterThanOrEqual(a.perSpeaker.first?.fillerCount ?? 0, 4)
    }

    func testQuestionMarkFillerNeedsQuestionMark() {
        // Plain "no" is a real word, not the tag filler "¿no?".
        let count = SpeakingAnalytics.countFillers(
            in: "no me parece, no lo veo claro",
            list: SpeakingAnalytics.fillers["es"]!)
        XCTAssertEqual(count, 0)
    }

    func testLongestMonologueSpansGaps() {
        let a = SpeakingAnalytics.compute(for: transcript([
            seg("You", 0, 10, "part one"),
            seg("You", 12, 30, "part two after a breath"),   // 2 s gap: same run
            seg("Others", 31, 40, "someone else"),
            seg("You", 41, 45, "short reply"),
        ]))
        let you = a.perSpeaker.first { $0.speaker == "You" }
        XCTAssertEqual(you?.longestMonologueSeconds ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(you?.longestMonologueStart ?? -1, 0, accuracy: 0.001)
    }

    func testLongMonologueBrokenByLongGap() {
        let a = SpeakingAnalytics.compute(for: transcript([
            seg("You", 0, 10, "part one"),
            seg("You", 20, 25, "much later"),  // 10 s gap: separate runs
        ]))
        let you = a.perSpeaker.first
        XCTAssertEqual(you?.longestMonologueSeconds ?? 0, 10, accuracy: 0.001)
    }

    func testEmptyTranscript() {
        let a = SpeakingAnalytics.compute(for: transcript([]))
        XCTAssertTrue(a.perSpeaker.isEmpty)
        XCTAssertEqual(a.totalWords, 0)
        XCTAssertEqual(a.meetingWPM, 0)
    }

    func testFillerRatePer100Words() {
        let text = "um " + Array(repeating: "word", count: 49).joined(separator: " ")
        let a = SpeakingAnalytics.compute(for: transcript([seg("You", 0, 20, text)]))
        XCTAssertEqual(a.perSpeaker.first?.fillerRate ?? 0, 2.0, accuracy: 0.001)
    }
}
