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
public struct Transcript: Codable, Identifiable {
    public var id = UUID()
    public var title: String
    public var startedAt: Date
    public var endedAt: Date
    public var segments: [TranscriptSegment]

    public init(id: UUID = UUID(), title: String, startedAt: Date, endedAt: Date,
                segments: [TranscriptSegment]) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// Segments sorted chronologically (the two streams are merged by time).
    public var ordered: [TranscriptSegment] {
        segments.sorted { $0.start < $1.start }
    }

    /// A readable plain-text rendering.
    public func plainText() -> String {
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short
        var out = "\(title)\n\(df.string(from: startedAt))\n\n"
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

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        directory = base.appendingPathComponent("ODE/Transcripts", isDirectory: true)
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
