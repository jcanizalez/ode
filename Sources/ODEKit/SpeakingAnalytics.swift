import Foundation
import NaturalLanguage

/// Speaking statistics computed from a stored transcript — pure on-device
/// text math, no models. Everything derives from segment text and timing.
public struct SpeakingAnalytics {
    public struct SpeakerStats {
        public let speaker: String
        public let words: Int
        /// Seconds actually spent talking (sum of segment durations).
        public let speakingSeconds: TimeInterval
        /// Words per minute of SPEAKING time, not wall clock.
        public let wordsPerMinute: Double
        public let fillerCount: Int
        /// Fillers per 100 words.
        public let fillerRate: Double
        public let longestMonologueSeconds: TimeInterval
        /// Start of the longest monologue — jump target into the transcript.
        public let longestMonologueStart: TimeInterval
    }

    /// Per speaker, in the transcript's first-appearance order.
    public let perSpeaker: [SpeakerStats]
    public let totalWords: Int
    public let meetingWPM: Double

    /// Filler words and phrases by language. Multi-word phrases are counted
    /// (and consumed) before single words so "you know" is one filler, not a
    /// false "know". Lists stay short and uncontroversial — the point is a
    /// trend, not a verdict.
    static let fillers: [String: [String]] = [
        "en": ["you know", "i mean", "sort of", "kind of",
               "um", "uh", "like", "basically", "actually", "literally"],
        "es": ["o sea", "en plan", "ya sabes",
               "este", "eh", "pues", "bueno", "digamos", "no?"],
    ]

    /// A pause this short between segments of the same speaker still counts
    /// as one continuous monologue (transcription splits on breaths).
    static let monologueGapTolerance: TimeInterval = 3

    public static func compute(for t: Transcript) -> SpeakingAnalytics {
        let ordered = t.ordered
        let language = dominantLanguage(of: ordered)
        let fillerList = fillers[language] ?? fillers["en"]!

        var stats: [SpeakerStats] = []
        for speaker in t.speakers {
            let mine = ordered.filter { $0.speaker == speaker }
            let words = mine.reduce(0) { $0 + wordCount($1.text) }
            let seconds = mine.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            let fillerHits = mine.reduce(0) { $0 + countFillers(in: $1.text, list: fillerList) }
            let monologue = longestMonologue(of: speaker, in: ordered)
            stats.append(SpeakerStats(
                speaker: speaker,
                words: words,
                speakingSeconds: seconds,
                wordsPerMinute: seconds > 0 ? Double(words) / (seconds / 60) : 0,
                fillerCount: fillerHits,
                fillerRate: words > 0 ? Double(fillerHits) * 100 / Double(words) : 0,
                longestMonologueSeconds: monologue.duration,
                longestMonologueStart: monologue.start))
        }
        let totalWords = stats.reduce(0) { $0 + $1.words }
        let totalSeconds = stats.reduce(0.0) { $0 + $1.speakingSeconds }
        return SpeakingAnalytics(
            perSpeaker: stats,
            totalWords: totalWords,
            meetingWPM: totalSeconds > 0 ? Double(totalWords) / (totalSeconds / 60) : 0)
    }

    // MARK: - Pieces (internal for tests)

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Which filler list applies. NLLanguageRecognizer over the whole text;
    /// English on any doubt.
    static func dominantLanguage(of segments: [TranscriptSegment]) -> String {
        let text = segments.map(\.text).joined(separator: " ")
        guard text.count >= 20 else { return "en" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4_000)))
        guard let lang = recognizer.dominantLanguage?.rawValue,
              fillers[lang] != nil else { return "en" }
        return lang
    }

    /// Count filler occurrences on word boundaries — "like" must not match
    /// inside "likely". Tokenize once (letters only, remembering whether a
    /// question mark touched the word, for tag fillers like "¿no?"), then
    /// match multi-word phrases first, consuming their tokens so they aren't
    /// recounted as single words.
    static func countFillers(in text: String, list: [String]) -> Int {
        struct Token { let word: String; let question: Bool }
        let tokens: [Token] = text.lowercased()
            .split { $0.isWhitespace || $0.isNewline }
            .compactMap { raw in
                let word = raw.filter { $0.isLetter }
                guard !word.isEmpty else { return nil }
                return Token(word: String(word),
                             question: raw.contains("?") || raw.contains("¿"))
            }
        guard !tokens.isEmpty else { return 0 }
        // A filler spelled with "?" ("no?") only matches a question token.
        let phrases: [[(word: String, question: Bool)]] = list
            .map { filler in
                filler.split(separator: " ").map { part in
                    (word: String(part.filter(\.isLetter)), question: part.contains("?"))
                }
            }
            .sorted { $0.count > $1.count }
        var consumed = [Bool](repeating: false, count: tokens.count)
        var count = 0
        for phrase in phrases {
            guard phrase.count <= tokens.count else { continue }
            for start in 0...(tokens.count - phrase.count) {
                var matches = true
                for (offset, part) in phrase.enumerated() {
                    let token = tokens[start + offset]
                    if consumed[start + offset] || token.word != part.word
                        || (part.question && !token.question) {
                        matches = false
                        break
                    }
                }
                if matches {
                    for offset in phrase.indices { consumed[start + offset] = true }
                    count += 1
                }
            }
        }
        return count
    }

    /// Longest run of consecutive segments by `speaker`, tolerating short
    /// gaps (transcription splits on breaths, not on turns).
    static func longestMonologue(of speaker: String, in ordered: [TranscriptSegment])
        -> (duration: TimeInterval, start: TimeInterval) {
        var best: (duration: TimeInterval, start: TimeInterval) = (0, 0)
        var runStart: TimeInterval?
        var runEnd: TimeInterval = 0
        func closeRun() {
            if let s = runStart, runEnd - s > best.duration {
                best = (runEnd - s, s)
            }
            runStart = nil
        }
        for seg in ordered {
            if seg.speaker == speaker {
                if runStart == nil || seg.start - runEnd > Self.monologueGapTolerance {
                    closeRun()
                    runStart = seg.start
                }
                runEnd = max(runEnd, seg.end)
            } else if seg.start - runEnd > 0.5 || seg.end > runEnd {
                // Someone else genuinely took the floor — the run is over.
                // (A fully overlapped interjection inside the window keeps
                // the monologue alive.)
                closeRun()
            }
        }
        closeRun()
        return best
    }
}
