import SwiftUI
import AppKit
import ODEKit

/// Drives the Meetings window: loading, filtering, grouping, AI generation.
@MainActor
final class MeetingsModel: ObservableObject {
    enum Filter { case all, starred }
    enum Tab { case summary, transcript, actions }

    @Published var transcripts: [Transcript] = []
    @Published var selectedID: Transcript.ID?
    @Published var search = ""
    @Published var filter: Filter = .all
    @Published var tab: Tab = .summary

    @Published var summarizing = false
    @Published var asking = false
    @Published var question = ""
    @Published var answer: String?
    @Published var aiError: String?

    var aiAvailable: Bool {
        if #available(macOS 26.0, *) { return MeetingAI.isAvailable }
        return false
    }
    var aiUnavailableReason: String? {
        if #available(macOS 26.0, *) { return MeetingAI.availabilityMessage() }
        return "On-device AI requires macOS 26 or later."
    }

    var selected: Transcript? { transcripts.first { $0.id == selectedID } }

    // MARK: - Loading / filtering

    func reload() {
        transcripts = TranscriptStore.shared.load()
        if selectedID == nil || !transcripts.contains(where: { $0.id == selectedID }) {
            selectedID = transcripts.first?.id
        }
    }

    var filtered: [Transcript] {
        transcripts.filter { t in
            (filter == .all || t.starred) &&
            (search.isEmpty
             || t.title.localizedCaseInsensitiveContains(search)
             || (t.summary ?? "").localizedCaseInsensitiveContains(search)
             || t.segments.contains { $0.text.localizedCaseInsensitiveContains(search) })
        }
    }

    struct Sectioned { let title: String; let items: [Transcript] }

    var groupedSections: [Sectioned] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { t -> String in
            if cal.isDateInToday(t.startedAt) { return "Today" }
            if cal.isDateInYesterday(t.startedAt) { return "Yesterday" }
            let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: t.startedAt)
        }
        // Preserve chronological section order by the newest item in each group.
        return groups.map { Sectioned(title: $0.key, items: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { ($0.items.first?.startedAt ?? .distantPast) > ($1.items.first?.startedAt ?? .distantPast) }
    }

    // MARK: - Actions

    func toggleStar(_ t: Transcript) {
        guard var copy = transcripts.first(where: { $0.id == t.id }) else { return }
        copy.starred.toggle()
        TranscriptStore.shared.save(copy)
        replace(copy)
    }

    func delete(_ t: Transcript) {
        TranscriptStore.shared.delete(t)
        transcripts.removeAll { $0.id == t.id }
        if selectedID == t.id { selectedID = transcripts.first?.id }
    }

    func copy(_ t: Transcript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.plainText(), forType: .string)
    }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([TranscriptStore.shared.directory])
    }

    func summarize(_ t: Transcript) {
        guard #available(macOS 26.0, *) else { aiError = aiUnavailableReason; return }
        aiError = nil
        summarizing = true
        Task {
            do {
                let insights = try await MeetingAI.insights(for: t)
                var copy = t
                copy.summary = insights.summary
                copy.keyPoints = insights.keyPoints
                copy.actionItems = insights.actionItems
                TranscriptStore.shared.save(copy)
                self.replace(copy)
            } catch {
                self.aiError = error.localizedDescription
            }
            self.summarizing = false
        }
    }

    func ask(_ t: Transcript) {
        guard #available(macOS 26.0, *) else { aiError = aiUnavailableReason; return }
        let q = question
        guard !q.isEmpty else { return }
        asking = true
        answer = nil
        Task {
            do {
                let a = try await MeetingAI.answer(q, about: t)
                self.answer = a
                self.question = ""
                // Persist the Q&A so it survives restarts.
                if var copy = self.transcripts.first(where: { $0.id == t.id }) {
                    copy.chat.append(ChatMessage(question: q, answer: a))
                    TranscriptStore.shared.save(copy)
                    self.replace(copy)
                }
            } catch {
                self.answer = "Couldn't answer: \(error.localizedDescription)"
            }
            self.asking = false
        }
    }

    /// Delete the currently selected meeting.
    func deleteSelected() {
        guard let t = selected else { return }
        delete(t)
    }

    private func replace(_ t: Transcript) {
        if let i = transcripts.firstIndex(where: { $0.id == t.id }) {
            transcripts[i] = t
        }
    }
}
