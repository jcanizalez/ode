import Foundation

/// A speaker-labeled, timestamped line in a transcript.
public struct TranscriptSegment: Codable, Identifiable {
    public var id = UUID()
    public let speaker: String       // e.g. "You", "Others", "Speaker 2"
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
    public var sourceApp: String?          // e.g. "Microsoft Teams", "zoom.us"
    public var starred: Bool = false
    public var summary: String?
    public var keyPoints: [String]?
    public var actionItems: [String]?
    public var chat: [ChatMessage] = []    // saved Ask-anything Q&A history

    public init(id: UUID = UUID(), title: String, startedAt: Date, endedAt: Date,
                segments: [TranscriptSegment], sourceApp: String? = nil,
                starred: Bool = false, summary: String? = nil,
                keyPoints: [String]? = nil, actionItems: [String]? = nil,
                chat: [ChatMessage] = []) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
        self.sourceApp = sourceApp
        self.starred = starred
        self.summary = summary
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.chat = chat
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
        if let ai = actionItems, !ai.isEmpty {
            out += "ACTION ITEMS\n" + ai.map { "• \($0)" }.joined(separator: "\n") + "\n\n"
        }
        out += "TRANSCRIPT\n"
        for s in ordered {
            let mm = Int(s.start) / 60, ss = Int(s.start) % 60
            out += String(format: "[%02d:%02d] %@: %@\n", mm, ss, s.speaker, s.text)
        }
        return out
    }
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
    }

    private func fileStem(for t: Transcript) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        return "\(df.string(from: t.startedAt))_\(t.id.uuidString.prefix(8))"
    }
}
