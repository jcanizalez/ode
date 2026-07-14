import Foundation
import FoundationModels

/// On-device meeting intelligence using Apple's Foundation Models. Generates a
/// summary, key points, and action items from a transcript, and answers
/// free-form questions — all locally and privately. No network, no cloud.
@available(macOS 26.0, *)
public enum MeetingAI {
    public struct Insights {
        public let summary: String
        public let keyPoints: [String]
        public let actionItems: [String]
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

    /// Generate summary + key points + action items from a transcript.
    public static func insights(for transcript: Transcript) async throws -> Insights {
        guard isAvailable else {
            throw AIError.unavailable(availabilityMessage() ?? "On-device AI unavailable.")
        }
        let body = transcriptText(transcript)

        let session = LanguageModelSession(instructions: """
            You are a meeting assistant. Given a transcript (speakers labeled
            "You" and "Others"), produce concise, accurate notes. Do not invent
            facts that are not in the transcript. Keep it brief and useful.
            """)

        let summary = try await session.respond(to: """
            Write a 2–3 sentence summary of this meeting.

            TRANSCRIPT:
            \(body)
            """).content

        let keyRaw = try await session.respond(to: """
            List the key points as short bullet lines (max 5). Output only the
            bullets, one per line, no numbering or extra text.

            TRANSCRIPT:
            \(body)
            """).content

        let actionRaw = try await session.respond(to: """
            List concrete action items / follow-ups as short lines (max 5). If
            there are none, output exactly "None". Output only the lines.

            TRANSCRIPT:
            \(body)
            """).content

        return Insights(
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: bullets(from: keyRaw),
            actionItems: actionRaw.localizedCaseInsensitiveContains("none")
                ? [] : bullets(from: actionRaw))
    }

    /// Answer a question about a meeting using the transcript as context.
    public static func answer(_ question: String, about transcript: Transcript) async throws -> String {
        guard isAvailable else {
            throw AIError.unavailable(availabilityMessage() ?? "On-device AI unavailable.")
        }
        let session = LanguageModelSession(instructions: """
            Answer questions about the meeting using only the transcript below.
            If the answer isn't in the transcript, say you don't see it.

            TRANSCRIPT:
            \(transcriptText(transcript))
            """)
        return try await session.respond(to: question).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Render the transcript for prompting, keeping it inside the on-device
    /// model's context window: long meetings are truncated to the most recent
    /// part (the part live questions are usually about anyway).
    /// (Internal for unit tests.)
    static func transcriptText(_ t: Transcript, maxChars: Int = 12_000) -> String {
        let full = t.ordered.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        guard full.count > maxChars else { return full }
        let tail = String(full.suffix(maxChars))
        // Cut at a line boundary so we don't start mid-sentence.
        let clean = tail.drop(while: { $0 != "\n" }).dropFirst()
        return "[Earlier part of the meeting omitted]\n" + clean
    }

    private static func bullets(from raw: String) -> [String] {
        raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•*\t")) }
            .filter { !$0.isEmpty }
    }
}
