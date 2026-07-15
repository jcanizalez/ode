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

    /// Segment to scroll to (and briefly highlight) in the transcript tab.
    @Published var scrollTarget: TranscriptSegment.ID?
    @Published var draftingRecap = false
    @Published var recapCopied = false

    /// Name used for "Mentions of you" (first name). Override via defaults.
    var userFirstName: String {
        let name = UserDefaults.standard.string(forKey: "ode.userName")
            .flatMap { $0.isEmpty ? nil : $0 } ?? NSFullUserName()
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    // Live meeting (in progress right now): pinned in the sidebar; questions
    // can be asked about it in real time — e.g. after stepping away.
    @Published var live: Transcript?
    @Published var viewingLive = false

    private weak var controller: ODEController?
    private var liveTimer: Timer?

    private var storeObserver: NSObjectProtocol?

    /// When true, select the live meeting as soon as one exists (panel's
    /// "Meeting in progress" row jumps straight to live notes).
    private var startOnLive: Bool

    init(controller: ODEController? = nil, startOnLive: Bool = false) {
        self.controller = controller
        self.startOnLive = startOnLive
        // Poll the in-progress transcript; segments arrive every few seconds
        // during a call, so a 3 s refresh feels live without wasted work.
        liveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLive() }
        }
        // Reload when transcripts change on disk (meeting saved,
        // auto-summary finished) so notes appear without reopening.
        storeObserver = NotificationCenter.default.addObserver(
            forName: .odeTranscriptsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        refreshLive()
    }

    deinit {
        liveTimer?.invalidate()
        if let o = storeObserver { NotificationCenter.default.removeObserver(o) }
    }

    func refreshLive() {
        let snapshot = controller?.liveMeeting
        let ended = (live != nil && snapshot == nil)
        live = snapshot
        if startOnLive, snapshot != nil {
            viewingLive = true
            startOnLive = false
        }
        if ended {
            // Meeting just finished: it's being saved — show it in the list.
            if viewingLive { viewingLive = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.reload()
            }
        }
    }

    /// Ask the on-device model about the meeting in progress. The exchange is
    /// attached to the meeting and persisted when it's saved.
    func askLive(_ t: Transcript) {
        guard #available(macOS 26.0, *) else { aiError = aiUnavailableReason; return }
        let q = question
        guard !q.isEmpty else { return }
        asking = true
        answer = nil
        Task {
            do {
                let a = try await MeetingAI.answer(q, about: t, userName: self.userFirstName)
                self.answer = a
                self.question = ""
                self.controller?.recordLiveChat(question: q, answer: a)
                self.refreshLive()
            } catch {
                self.answer = "Couldn't answer: \(error.localizedDescription)"
            }
            self.asking = false
        }
    }

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
                let insights = try await MeetingAI.insights(for: t, userName: self.userFirstName)
                var copy = t
                copy.summary = insights.summary
                copy.keyPoints = insights.keyPoints
                copy.actionItems = insights.actionItems
                copy.decisions = insights.decisions.isEmpty ? nil : insights.decisions
                copy.openQuestions = insights.openQuestions.isEmpty ? nil : insights.openQuestions
                copy.chapters = insights.chapters.isEmpty ? nil : insights.chapters
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
                let a = try await MeetingAI.answer(q, about: t, userName: self.userFirstName)
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

    /// Rename a diarized speaker across the transcript ("Speaker 1" → "Igor").
    func renameSpeaker(in t: Transcript, from old: String, to new: String) {
        guard var copy = transcripts.first(where: { $0.id == t.id }) else { return }
        guard copy.renameSpeaker(old, to: new) else { return }
        TranscriptStore.shared.save(copy)
        replace(copy)
    }

    /// Jump the transcript tab to the segment nearest `seconds`.
    func jump(to seconds: TimeInterval, in t: Transcript) {
        let target = t.ordered.last(where: { $0.start <= seconds + 0.5 })
            ?? t.ordered.first
        guard let target else { return }
        tab = .transcript
        scrollTarget = target.id
    }

    /// Draft a recap email on-device and copy it to the clipboard.
    func draftRecapEmail(_ t: Transcript) {
        guard #available(macOS 26.0, *) else { aiError = aiUnavailableReason; return }
        draftingRecap = true
        recapCopied = false
        Task {
            do {
                let email = try await MeetingAI.recapEmail(for: t, from: self.userFirstName)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(email, forType: .string)
                self.recapCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.recapCopied = false
                }
            } catch {
                self.aiError = error.localizedDescription
            }
            self.draftingRecap = false
        }
    }

    private func replace(_ t: Transcript) {
        if let i = transcripts.firstIndex(where: { $0.id == t.id }) {
            transcripts[i] = t
        }
    }
}
