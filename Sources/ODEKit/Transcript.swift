import Foundation

/// A speaker-labeled, timestamped line in a transcript.
public struct TranscriptSegment: Codable, Identifiable {
    public var id = UUID()
    public var speaker: String       // e.g. "You", "Others", "Speaker 2", "Igor"
    public let start: TimeInterval   // seconds from meeting start
    public let end: TimeInterval
    public let text: String

    public init(speaker: String, start: TimeInterval, end: TimeInterval, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A follow-up task extracted from the meeting, with the responsible speaker
/// when one was stated ("Igor will send the doc" → owner "Igor").
public struct ActionItem: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var text: String
    public var owner: String?

    public init(text: String, owner: String? = nil) {
        self.text = text
        self.owner = owner
    }
}

/// A topic-level chapter of the meeting ("Assessment Review — 03:32"),
/// with detail bullets. Timestamps let the UI jump into the transcript.
public struct Chapter: Codable, Identifiable {
    public var id = UUID()
    public var title: String
    public var startSeconds: TimeInterval
    public var bullets: [String]

    public init(title: String, startSeconds: TimeInterval, bullets: [String]) {
        self.title = title
        self.startSeconds = startSeconds
        self.bullets = bullets
    }
}

/// A saved meeting transcript.
/// A saved Ask-anything exchange about a meeting.
public struct ChatMessage: Codable, Identifiable {
    public var id = UUID()
    public let question: String
    public let answer: String
    public let date: Date
    public init(question: String, answer: String, date: Date = Date()) {
        self.question = question; self.answer = answer; self.date = date
    }
}

public struct Transcript: Codable, Identifiable {
    public var id = UUID()
    public var title: String
    public var startedAt: Date
    public var endedAt: Date
    public var segments: [TranscriptSegment]

    // Optional metadata / cached AI output.
    public var sourceApp: String?          // e.g. "Microsoft Teams", "Zoom"
    public var attendees: [String]?        // first names from the calendar event
    public var starred: Bool = false
    public var summary: String?
    public var keyPoints: [String]?
    public var actionItems: [ActionItem]?
    public var decisions: [String]?
    public var openQuestions: [String]?
    public var chapters: [Chapter]?
    public var chat: [ChatMessage] = []    // saved Ask-anything Q&A history
    /// Audio recording of the call, as a filename RELATIVE to the transcript
    /// store directory (the store can move; absolute paths go stale).
    public var recordingFile: String?

    public init(id: UUID = UUID(), title: String, startedAt: Date, endedAt: Date,
                segments: [TranscriptSegment], sourceApp: String? = nil,
                attendees: [String]? = nil,
                starred: Bool = false, summary: String? = nil,
                keyPoints: [String]? = nil, actionItems: [ActionItem]? = nil,
                decisions: [String]? = nil, openQuestions: [String]? = nil,
                chapters: [Chapter]? = nil,
                chat: [ChatMessage] = [],
                recordingFile: String? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
        self.sourceApp = sourceApp
        self.attendees = attendees
        self.starred = starred
        self.summary = summary
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.chapters = chapters
        self.chat = chat
        self.recordingFile = recordingFile
    }

    // MARK: - Codable migration

    private enum CodingKeys: String, CodingKey {
        case id, title, startedAt, endedAt, segments, sourceApp, attendees,
             starred, summary, keyPoints, actionItems, decisions,
             openQuestions, chapters, chat, recordingFile
    }

    /// Custom decode so transcripts saved by older versions still load:
    /// `actionItems` used to be `[String]` (no owners), and the v0.8 fields
    /// don't exist in old files.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees)
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints)
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions)
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions)
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters)
        chat = try c.decodeIfPresent([ChatMessage].self, forKey: .chat) ?? []
        recordingFile = try c.decodeIfPresent(String.self, forKey: .recordingFile)
        if let items = try? c.decodeIfPresent([ActionItem].self, forKey: .actionItems) {
            actionItems = items
        } else if let legacy = try? c.decodeIfPresent([String].self, forKey: .actionItems) {
            actionItems = legacy.map { ActionItem(text: $0) }
        } else {
            actionItems = nil
        }
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// Segments sorted chronologically (the two streams are merged by time).
    public var ordered: [TranscriptSegment] {
        segments.sorted { $0.start < $1.start }
    }

    /// Distinct speakers in first-appearance order.
    public var speakers: [String] {
        var seen: [String] = []
        for s in ordered where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }

    /// Fraction of total spoken time per speaker (0...1), summing ~1.
    public var talkTime: [(speaker: String, fraction: Double)] {
        var totals: [String: Double] = [:]
        for s in segments {
            totals[s.speaker, default: 0] += max(0, s.end - s.start)
        }
        let sum = totals.values.reduce(0, +)
        guard sum > 0 else { return speakers.map { ($0, 0) } }
        return totals.sorted { $0.value > $1.value }
            .map { ($0.key, $0.value / sum) }
    }

    public var hasAI: Bool { summary != nil }

    /// Rename a diarized speaker ("Speaker 1" → "Igor") everywhere it appears:
    /// segments and action-item owners. Renaming *to* an existing label merges
    /// the speakers (useful when diarization split one person in two).
    /// "You" is protected — it anchors talk-time and styling semantics.
    /// Cached AI prose (summary/chapters) is not rewritten; re-summarize for
    /// that. Returns false when the rename is not allowed.
    @discardableResult
    public mutating func renameSpeaker(_ old: String, to new: String) -> Bool {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, old != "You", trimmed != old else { return false }
        for i in segments.indices where segments[i].speaker == old {
            segments[i].speaker = trimmed
        }
        if actionItems != nil {
            for i in actionItems!.indices where actionItems![i].owner == old {
                actionItems![i].owner = trimmed
            }
        }
        return true
    }

    /// Segments (by other speakers) that mention `name` as a whole word,
    /// case- and diacritic-insensitively — "where was I mentioned?".
    public func mentions(of name: String) -> [TranscriptSegment] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: trimmed))\\b"
        return ordered.filter { seg in
            seg.speaker != "You" &&
            seg.text.range(of: pattern,
                           options: [.regularExpression, .caseInsensitive,
                                     .diacriticInsensitive]) != nil
        }
    }

    /// A readable plain-text rendering.
    public func plainText() -> String {
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short
        var out = "\(title)\n\(df.string(from: startedAt))\n\n"
        if let summary {
            out += "SUMMARY\n\(summary)\n\n"
        }
        if let kp = keyPoints, !kp.isEmpty {
            out += "KEY POINTS\n" + kp.map { "• \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if let ch = chapters, !ch.isEmpty {
            out += "CHAPTERS\n" + ch.map { c in
                let mm = Int(c.startSeconds) / 60, ss = Int(c.startSeconds) % 60
                var line = String(format: "[%02d:%02d] %@", mm, ss, c.title)
                if !c.bullets.isEmpty {
                    line += "\n" + c.bullets.map { "    • \($0)" }.joined(separator: "\n")
                }
                return line
            }.joined(separator: "\n") + "\n\n"
        }
        if let d = decisions, !d.isEmpty {
            out += "DECISIONS\n" + d.map { "• \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if let q = openQuestions, !q.isEmpty {
            out += "OPEN QUESTIONS\n" + q.map { "• \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if let ai = actionItems, !ai.isEmpty {
            out += "ACTION ITEMS\n" + ai.map { item in
                "• \(item.text)\(item.owner.map { " — \($0)" } ?? "")"
            }.joined(separator: "\n") + "\n\n"
        }
        out += "TRANSCRIPT\n"
        for s in ordered {
            let mm = Int(s.start) / 60, ss = Int(s.start) % 60
            out += String(format: "[%02d:%02d] %@: %@\n", mm, ss, s.speaker, s.text)
        }
        return out
    }
}

public extension Notification.Name {
    /// Posted after a transcript is saved (new meeting, auto-summary,
    /// rename, star…). UI observers reload their lists.
    static let odeTranscriptsChanged = Notification.Name("odeTranscriptsChanged")
}

/// Stores transcripts as JSON (+ a readable .txt) under Application Support.
public final class TranscriptStore {
    public static let shared = TranscriptStore()

    public let directory: URL

    public convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        self.init(directory: base.appendingPathComponent("ODE/Transcripts", isDirectory: true))
    }

    /// Store rooted at a custom directory (tests use a temp dir).
    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    public func save(_ transcript: Transcript) {
        let base = directory.appendingPathComponent(fileStem(for: transcript))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(transcript).write(to: base.appendingPathExtension("json"))
            try transcript.plainText().data(using: .utf8)?
                .write(to: base.appendingPathExtension("txt"))
            NotificationCenter.default.post(name: .odeTranscriptsChanged, object: nil)
        } catch {
            NSLog("ODE: failed to save transcript: \(error.localizedDescription)")
        }
    }

    public func load() -> [Transcript] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Transcript.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ transcript: Transcript) {
        let base = directory.appendingPathComponent(fileStem(for: transcript))
        try? FileManager.default.removeItem(at: base.appendingPathExtension("json"))
        try? FileManager.default.removeItem(at: base.appendingPathExtension("txt"))
        if let url = recordingURL(for: transcript) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Absolute URL of the call recording, nil when the meeting has none or
    /// the file has since disappeared.
    public func recordingURL(for t: Transcript) -> URL? {
        guard let name = t.recordingFile else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Shared basename for a transcript's sidecar files (.json/.txt/.m4a).
    public func fileStem(for t: Transcript) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        return "\(df.string(from: t.startedAt))_\(t.id.uuidString.prefix(8))"
    }
}
