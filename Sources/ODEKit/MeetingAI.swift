import Foundation
import FoundationModels

// MARK: - Prompt rendering & fallback parsing (model-free, unit-testable)

/// Text plumbing for the on-device meeting AI: transcript rendering for
/// prompts, timestamp parsing, and the line-format fallback parser used when
/// guided generation fails. Kept availability-free so tests cover it.
public enum MeetingNotesFormat {

    /// Render a transcript as "[mm:ss] Speaker: text" lines. Consecutive
    /// segments by the same speaker merge into one line (first timestamp
    /// kept) to cut token count. If the result exceeds `maxChars`, lines are
    /// dropped uniformly (never tail-truncated) so chapters keep full time
    /// coverage of the meeting.
    ///
    /// `youName` replaces the "You" label so the model knows who the user is
    /// ("Javier (me)") — otherwise notes say "You will send the doc" and the
    /// model only learns the user's name if someone happens to say it aloud.
    public static func timestampedText(_ t: Transcript, maxChars: Int = 8_000,
                                       youName: String? = nil) -> String {
        var lines: [String] = []
        var currentSpeaker: String?
        for seg in t.ordered {
            let label = (seg.speaker == "You" && youName != nil)
                ? "\(youName!) (me)" : seg.speaker
            // Merge consecutive same-speaker segments, but cap the merged
            // line: long monologues otherwise produce multi-thousand-char
            // lines that defeat the size budget (and starve chapters of
            // timestamps). Over the cap, a fresh timestamped line starts.
            if seg.speaker == currentSpeaker, let last = lines.last,
               last.count + seg.text.count < 400 {
                lines[lines.count - 1] = last + " " + seg.text
            } else {
                let mm = Int(seg.start) / 60, ss = Int(seg.start) % 60
                lines.append(String(format: "[%02d:%02d] %@: %@",
                                    mm, ss, label, seg.text))
                currentSpeaker = seg.speaker
            }
        }
        var text = lines.joined(separator: "\n")
        // Uniform downsampling: drop every k-th line until it fits. The step
        // is clamped to the line count — otherwise, when the text sits just
        // over budget, the computed step exceeds the number of lines, the
        // filter removes nothing, and this loop spins forever (a real
        // meeting's transcript hung the notes pipeline exactly this way).
        while text.count > maxChars && lines.count > 4 {
            let keepRatio = Double(maxChars) / Double(text.count)
            let ideal = Int((1.0 / max(0.01, 1.0 - keepRatio)).rounded())
            let step = min(max(2, ideal), lines.count)  // ≥1 line drops per pass
            lines = lines.enumerated().filter { $0.offset % step != step - 1 }.map(\.element)
            text = lines.joined(separator: "\n")
        }
        // Absolute guarantee — the model's context is a hard limit.
        if text.count > maxChars { text = String(text.prefix(maxChars)) }
        return text
    }

    /// Whether a transcript has enough substance to be worth summarizing
    /// (skips 20-second accidental captures).
    public static func hasSubstance(_ t: Transcript, minChars: Int = 300) -> Bool {
        t.segments.reduce(0) { $0 + $1.text.count } >= minChars
    }

    /// Parse "mm:ss" (or "h:mm:ss") to seconds; nil when malformed.
    public static func parseTimestamp(_ s: String) -> TimeInterval? {
        let parts = s.trimmingCharacters(in: .whitespaces)
            .split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        let nums = parts.compactMap { Double($0) }
        guard nums.count == parts.count else { return nil }
        return nums.reduce(0) { $0 * 60 + $1 }
    }

    /// Validate, sort and dedup model-produced chapters against the meeting
    /// duration; drops entries with unparseable or out-of-range timestamps.
    public static func cleanChapters(_ raw: [(title: String, start: String, bullets: [String])],
                                     duration: TimeInterval) -> [Chapter] {
        var out: [Chapter] = []
        for r in raw {
            guard let t = parseTimestamp(r.start), t >= 0, t <= duration + 60,
                  !r.title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if out.contains(where: { abs($0.startSeconds - t) < 1 }) { continue }
            out.append(Chapter(title: r.title.trimmingCharacters(in: .whitespaces),
                               startSeconds: t, bullets: r.bullets))
        }
        return out.sorted { $0.startSeconds < $1.startSeconds }
    }

    public struct ParsedNotes {
        public var summary = ""
        public var keyPoints: [String] = []
        public var decisions: [String] = []
        public var openQuestions: [String] = []
        public var actionItems: [ActionItem] = []
        public var chapters: [(title: String, start: String, bullets: [String])] = []
    }

    /// Fallback parser for the plain prefixed-line prompt format:
    ///   SUMMARY: …            POINT: …           DECISION: …
    ///   OPEN: …               ACTION: text | owner
    ///   CHAPTER: mm:ss | title | bullet; bullet
    public static func parseFallback(_ raw: String) -> ParsedNotes {
        var notes = ParsedNotes()
        for line in raw.split(separator: "\n") {
            let l = line.trimmingCharacters(in: CharacterSet(charactersIn: " -•*\t"))
            guard let colon = l.firstIndex(of: ":") else { continue }
            let tag = l[..<colon].uppercased()
            let body = String(l[l.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            switch tag {
            case "SUMMARY":
                notes.summary = notes.summary.isEmpty ? body : notes.summary + " " + body
            case "POINT": notes.keyPoints.append(body)
            case "DECISION": notes.decisions.append(body)
            case "OPEN": notes.openQuestions.append(body)
            case "ACTION":
                let parts = body.split(separator: "|", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let owner = parts.count > 1 && !parts[1].isEmpty
                    && parts[1].lowercased() != "none" ? parts[1] : nil
                notes.actionItems.append(ActionItem(text: parts[0], owner: owner))
            case "CHAPTER":
                let parts = body.split(separator: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count >= 2 else { continue }
                let bullets = parts.count > 2
                    ? parts[2].split(separator: ";").map {
                        $0.trimmingCharacters(in: .whitespaces)
                      }.filter { !$0.isEmpty }
                    : []
                notes.chapters.append((title: parts[1], start: parts[0], bullets: bullets))
            default: continue
            }
        }
        return notes
    }
}

// MARK: - On-device meeting intelligence

/// On-device meeting intelligence using Apple's Foundation Models. Generates
/// chaptered notes, decisions, open questions, owned action items, titles and
/// recap emails from a transcript — all locally and privately.
@available(macOS 26.0, *)
public enum MeetingAI {
    public struct Insights {
        public let summary: String
        public let keyPoints: [String]
        public let decisions: [String]
        public let openQuestions: [String]
        public let actionItems: [ActionItem]
        public let chapters: [Chapter]
    }

    public enum AIError: Error, LocalizedError {
        case unavailable(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable(let why): return why
            }
        }
    }

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public static func availabilityMessage() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "Apple Intelligence isn't supported on this Mac."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in System Settings to use AI summaries."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Try again shortly."
        case .unavailable:
            return "On-device AI is currently unavailable."
        }
    }

    /// Race a model call against a deadline — on-device generation must never
    /// hang the notes pipeline indefinitely (observed with certain transcript
    /// shapes). On timeout the caller's fallback path takes over.
    static func withTimeout<T: Sendable>(
        _ seconds: Double = 90,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AIError.unavailable("On-device model timed out.")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: Guided-generation output shapes

    @Generable
    struct GeneratedNotes {
        @Guide(description: "2-3 sentence meeting summary")
        var summary: String
        @Guide(description: "Key points discussed", .maximumCount(5))
        var keyPoints: [String]
        @Guide(description: "Decisions that were explicitly made; empty if none", .maximumCount(5))
        var decisions: [String]
        @Guide(description: "Questions raised but left unresolved; empty if none", .maximumCount(5))
        var openQuestions: [String]
        @Guide(description: "Concrete follow-up tasks", .maximumCount(6))
        var actionItems: [GeneratedActionItem]
    }

    @Generable
    struct GeneratedActionItem {
        @Guide(description: "The follow-up task")
        var text: String
        @Guide(description: "Speaker responsible, exactly as named in the transcript, only if stated")
        var owner: String?
    }

    @Generable
    struct GeneratedChapter {
        @Guide(description: "Short topic title, 2-6 words")
        var title: String
        @Guide(description: "Timestamp where the topic starts, copied exactly from the transcript, format mm:ss")
        var start: String
        @Guide(description: "1-3 detail bullets", .maximumCount(3))
        var bullets: [String]
    }

    // MARK: Notes

    /// Generate the full meeting notes: summary, key points, decisions, open
    /// questions, owned action items, and timestamped chapters. Two model
    /// calls on fresh sessions (the transcript is large; reusing a session
    /// accumulates it against the model's context window).
    /// `userName` identifies who "You" is, so notes attribute by name.
    public static func insights(for transcript: Transcript,
                                userName: String? = nil) async throws -> Insights {
        guard isAvailable else {
            throw AIError.unavailable(availabilityMessage() ?? "On-device AI unavailable.")
        }
        let body = MeetingNotesFormat.timestampedText(transcript, youName: userName)

        // Call 1: notes.
        var notes = MeetingNotesFormat.ParsedNotes()
        do {
            let g = try await withTimeout {
                let session = LanguageModelSession(instructions: """
                    You are a meeting assistant. Speakers are labeled by name (or
                    "You"/"Speaker N"). Be concise and accurate; never invent facts
                    that are not in the transcript.
                    """)
                return try await session.respond(
                    to: "Produce meeting notes for this transcript.\n\nTRANSCRIPT:\n\(body)",
                    generating: GeneratedNotes.self).content
            }
            notes.summary = g.summary
            notes.keyPoints = g.keyPoints
            notes.decisions = g.decisions
            notes.openQuestions = g.openQuestions
            notes.actionItems = g.actionItems.map {
                ActionItem(text: $0.text, owner: $0.owner)
            }
        } catch {
            notes = try await fallbackNotes(body: body)
        }

        // Call 2: chapters (fresh session).
        var rawChapters: [(title: String, start: String, bullets: [String])] = []
        do {
            let g = try await withTimeout {
                let session = LanguageModelSession(instructions: """
                    You segment meeting transcripts into topical chapters. Copy
                    timestamps exactly as they appear in the transcript.
                    """)
                return try await session.respond(
                    to: """
                    Split this meeting into 2-6 topical chapters. For each: a short
                    title, the mm:ss timestamp where the topic starts (copied from
                    the transcript), and 1-3 detail bullets.

                    TRANSCRIPT:
                    \(body)
                    """,
                    generating: [GeneratedChapter].self).content
            }
            rawChapters = g.map { ($0.title, $0.start, $0.bullets) }
        } catch {
            // Chapters are additive — a failure shouldn't sink the notes.
            rawChapters = []
        }

        return Insights(
            summary: notes.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: notes.keyPoints,
            decisions: notes.decisions,
            openQuestions: notes.openQuestions,
            actionItems: notes.actionItems,
            chapters: MeetingNotesFormat.cleanChapters(rawChapters,
                                                       duration: transcript.duration))
    }

    /// Plain-prompt fallback when guided generation fails (guardrails, older
    /// model states): prefixed lines parsed by MeetingNotesFormat.
    private static func fallbackNotes(body: String) async throws -> MeetingNotesFormat.ParsedNotes {
        let session = LanguageModelSession(instructions: """
            You are a meeting assistant. Output ONLY lines in these formats,
            nothing else:
            SUMMARY: <2-3 sentence summary>
            POINT: <key point>              (max 5)
            DECISION: <decision made>       (max 5, omit if none)
            OPEN: <unresolved question>     (max 5, omit if none)
            ACTION: <task> | <owner or none>  (max 6)
            """)
        let raw = try await withTimeout {
            try await session.respond(
                to: "Produce meeting notes.\n\nTRANSCRIPT:\n\(body)").content
        }
        return MeetingNotesFormat.parseFallback(raw)
    }

    // MARK: Title

    /// A short title from the transcript's opening (topics are set early).
    /// Returns nil for tiny captures or on any failure.
    public static func title(forSegments segments: [TranscriptSegment]) async -> String? {
        guard isAvailable else { return nil }
        let opening = segments.sorted { $0.start < $1.start }
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
            .prefix(4_000)
        // Enough substance for a meaningful title (skips 10 s accidental captures).
        guard opening.count >= 200 else { return nil }
        let session = LanguageModelSession(instructions: """
            You title meetings. Output only the title: 3-6 words, no quotes,
            no trailing punctuation. CRITICAL: write the title in the SAME
            language the participants speak in the transcript (if they speak
            Spanish, the title must be Spanish).
            """)
        guard let raw = try? await withTimeout(45, {
            try await session.respond(
                to: "Title this meeting in the participants' language.\n\nTRANSCRIPT START:\n\(opening)").content
        }) else { return nil }
        // Models sometimes echo the title on multiple lines — keep the first.
        let firstLine = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? ""
        let cleaned = firstLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”.,"))
        guard !cleaned.isEmpty, cleaned.count <= 80 else { return nil }
        return cleaned
    }

    // MARK: Recap email

    /// A copy-ready recap email. Prefers cached insights (fast, consistent
    /// with what the user sees); falls back to the transcript.
    public static func recapEmail(for t: Transcript, from senderName: String) async throws -> String {
        guard isAvailable else {
            throw AIError.unavailable(availabilityMessage() ?? "On-device AI unavailable.")
        }
        var context = "MEETING: \(t.title)\n"
        if let s = t.summary {
            context += "SUMMARY: \(s)\n"
            if let d = t.decisions, !d.isEmpty {
                context += "DECISIONS:\n" + d.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            if let a = t.actionItems, !a.isEmpty {
                context += "ACTION ITEMS:\n" + a.map {
                    "- \($0.text)\($0.owner.map { " (\($0))" } ?? "")"
                }.joined(separator: "\n") + "\n"
            }
        } else {
            context += "TRANSCRIPT:\n\(MeetingNotesFormat.timestampedText(t, maxChars: 6_000))\n"
        }
        let session = LanguageModelSession(instructions: """
            You draft short, professional recap emails in the meeting's own
            language. Output exactly: a "Subject: …" line, a blank line, then
            the body. Sign off with the sender's name. No preamble.
            """)
        return try await withTimeout {
            try await session.respond(to: """
                Draft the recap email for this meeting. Sender: \(senderName).

                \(context)
                """).content
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Q&A

    /// Answer a question about a meeting using the transcript as context.
    /// `userName` lets "what did I commit to?" resolve who "I" is.
    public static func answer(_ question: String, about transcript: Transcript,
                              userName: String? = nil) async throws -> String {
        guard isAvailable else {
            throw AIError.unavailable(availabilityMessage() ?? "On-device AI unavailable.")
        }
        let session = LanguageModelSession(instructions: """
            Answer questions about the meeting using only the transcript below.
            The person asking is the participant marked "(me)". If the answer
            isn't in the transcript, say you don't see it.

            TRANSCRIPT:
            \(MeetingNotesFormat.timestampedText(transcript, youName: userName))
            """)
        return try await session.respond(to: question).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
