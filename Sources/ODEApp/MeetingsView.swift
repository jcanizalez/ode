import SwiftUI
import AppKit
import ODEKit

// Speaker avatar colors, matching the design language.
enum SpeakerStyle {
    /// Ten hues spaced around the circle, all mid-brightness so the white
    /// initials stay legible on the dark panel. Deliberately discrete: the
    /// old continuous hue mapping let two speakers land a few degrees apart
    /// and read as the same colour.
    private static let palette: [Color] = [
        Color(hue: 0.61, saturation: 0.62, brightness: 0.86),  // blue
        Color(hue: 0.94, saturation: 0.55, brightness: 0.85),  // pink
        Color(hue: 0.38, saturation: 0.58, brightness: 0.76),  // green
        Color(hue: 0.08, saturation: 0.70, brightness: 0.90),  // orange
        Color(hue: 0.78, saturation: 0.50, brightness: 0.85),  // purple
        Color(hue: 0.48, saturation: 0.60, brightness: 0.78),  // teal
        Color(hue: 0.99, saturation: 0.62, brightness: 0.84),  // red
        Color(hue: 0.15, saturation: 0.68, brightness: 0.82),  // amber
        Color(hue: 0.54, saturation: 0.62, brightness: 0.82),  // cyan
        Color(hue: 0.24, saturation: 0.58, brightness: 0.74),  // lime
    ]

    static func color(_ speaker: String) -> Color {
        switch speaker.lowercased() {
        case "you":    return Color.accentColor
        case "others": return Color.orange
        default:       return palette[SpeakerBadge.paletteIndex(for: speaker)]
        }
    }

    static func color(at index: Int) -> Color { palette[index % palette.count] }

    static func initials(_ speaker: String) -> String {
        SpeakerBadge.initials(for: speaker)
    }
}

/// Colours for the speakers of one meeting, with collisions resolved so no
/// two people in the same transcript wear the same badge.
struct SpeakerPalette {
    private let indices: [String: Int]

    init(_ speakers: [String]) {
        indices = SpeakerBadge.paletteIndices(for: speakers)
    }

    func color(_ speaker: String) -> Color {
        switch speaker.lowercased() {
        case "you":    return Color.accentColor
        case "others": return Color.orange
        default:
            // A speaker outside this meeting (an action-item owner the AI
            // named, say) still gets a stable colour from their name.
            guard let index = indices[speaker] else { return SpeakerStyle.color(speaker) }
            return SpeakerStyle.color(at: index)
        }
    }
}

struct SpeakerAvatar: View {
    let speaker: String
    var size: CGFloat = 26
    /// The meeting's palette, so two speakers never share a colour. Nil
    /// where no meeting is in scope — falls back to the name's own slot.
    var palette: SpeakerPalette?
    var body: some View {
        ZStack {
            Circle().fill(palette?.color(speaker) ?? SpeakerStyle.color(speaker))
            Text(SpeakerStyle.initials(speaker))
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// The full "ODE — Meetings" window: meeting list + detail with Summary,
/// Transcript and Action items tabs, plus on-device AI.
struct MeetingsView: View {
    @StateObject private var model: MeetingsModel
    @State private var confirmDelete = false
    @State private var renameTarget: String?
    @State private var renameText = ""
    /// Whether the speaker being renamed has a kept voice sample, so the
    /// sheet can offer to remember it.
    @State private var renameHasVoice = false

    init(controller: ODEController? = nil, showLive: Bool = false) {
        _model = StateObject(wrappedValue: MeetingsModel(controller: controller,
                                                         startOnLive: showLive))
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
            detail.frame(minWidth: 480)
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(Color(white: 0.07))
        .onAppear { model.reload() }
        .alert("Name \"\(renameTarget ?? "")\"",
               isPresented: Binding(get: { renameTarget != nil },
                                    set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            // When a voice sample was kept, remembering it is the better
            // default: it is the whole point of naming someone.
            if renameHasVoice {
                Button("Name & Remember Voice") { applyRename(rememberVoice: true) }
                Button("Name Only") { applyRename(rememberVoice: false) }
            } else {
                Button("Rename") { applyRename(rememberVoice: false) }
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text(renameHasVoice
                 ? "The name appears in the transcript, talk time and action items. ODE kept a few seconds of this voice — remember it and future meetings will label them by name automatically."
                 : "The new name appears in the transcript, talk time and action items.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Meetings").font(.system(size: 20, weight: .heavy)).foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                TextField("Search meetings…", text: $model.search)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
            .padding(.horizontal, 14)

            HStack(spacing: 8) {
                filterChip(.all, "All")
                filterChip(.starred, "Starred")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 11)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let live = model.live {
                        liveRow(live)
                    }
                    ForEach(model.groupedSections, id: \.title) { section in
                        Text(section.title.uppercased())
                            .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                        ForEach(section.items) { t in row(t) }
                    }
                    if model.filtered.isEmpty { emptyState }
                }
                .padding(.bottom, 12)
            }

        }
        .background(Color(white: 0.09))
    }

    private func filterChip(_ f: MeetingsModel.Filter, _ label: String) -> some View {
        Button { model.filter = f } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.filter == f ? .white : .white.opacity(0.5))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(model.filter == f ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    /// Pinned row for the meeting happening right now.
    private func liveRow(_ t: Transcript) -> some View {
        Button { model.viewingLive = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text(t.title).font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Text("LIVE")
                        .font(.system(size: 9, weight: .heavy)).tracking(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                }
                Text(t.ordered.last?.text ?? "Listening…")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(model.viewingLive ? Color.red.opacity(0.12) : Color.red.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(model.viewingLive ? Color.red.opacity(0.5) : Color.red.opacity(0.2),
                                lineWidth: 1)))
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ t: Transcript) -> some View {
        let selected = model.selectedID == t.id && !model.viewingLive
        return Button { model.selectedID = t.id; model.viewingLive = false } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    Text(t.title).font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Text(timeText(t.startedAt)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
                Text(t.summary ?? previewLine(t))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                HStack(spacing: 6) {
                    ForEach(t.speakers.prefix(4), id: \.self) { SpeakerAvatar(speaker: $0, size: 18, palette: palette(t)) }
                    Text(durationText(t.duration))
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.15)))
                    if let app = t.sourceApp {
                        Text(app).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(t.starred ? "Unstar" : "Star") { model.toggleStar(t) }
            Button("Copy transcript") { model.copy(t) }
            Button("Show in Finder") { model.reveal() }
            Divider()
            Button("Delete", role: .destructive) { model.delete(t) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 26)).foregroundStyle(.white.opacity(0.3))
            Text("No meetings yet").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            Text("Enable Transcripts and join a call.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if model.viewingLive, let t = model.live {
            liveDetail(t)
                .translationDriver(model: model) { model.live }
        } else if let t = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(t)
                Divider().overlay(Color.white.opacity(0.08))
                peopleRow(t)
                Divider().overlay(Color.white.opacity(0.08))
                tabBar(t)
                Divider().overlay(Color.white.opacity(0.08))
                ScrollView {
                    switch model.tab {
                    case .summary:  summaryTab(t)
                    case .transcript: transcriptTab(t)
                    case .actions:  actionsTab(t)
                    case .analytics: analyticsTab(t)
                    }
                }
                askSection(t)
            }
            .background(Color(white: 0.07))
            .translationDriver(model: model) { model.selected }
        } else {
            Text("Select a meeting").foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(white: 0.07))
        }
    }

    /// Detail pane for the meeting in progress: growing transcript, saved live
    /// Q&A, and an ask bar answering from the transcript-so-far. Catch up on
    /// what you missed without waiting for the meeting to end.
    private func liveDetail(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text(t.title).font(.system(size: 20, weight: .heavy)).foregroundStyle(.white)
                        Text("LIVE")
                            .font(.system(size: 10, weight: .heavy)).tracking(0.8)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    }
                    HStack(spacing: 10) {
                        Text("Started \(timeText(t.startedAt))").foregroundStyle(.white.opacity(0.5))
                        Text(durationText(t.duration)).foregroundStyle(.white.opacity(0.5))
                        HStack(spacing: -5) {
                            ForEach(t.speakers.prefix(4), id: \.self) { SpeakerAvatar(speaker: $0, size: 20, palette: palette(t)) }
                        }
                    }
                    .font(.system(size: 12))
                }
                Spacer()
            }
            .padding(16)
            Divider().overlay(Color.white.opacity(0.08))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        transcriptTab(t)
                        if !t.chat.isEmpty {
                            section("LIVE Q&A") {
                                ForEach(t.chat) { msg in qaCard(msg) }
                            }
                            .padding(.horizontal, 18)
                        }
                        Color.clear.frame(height: 1).id("live-bottom")
                    }
                }
                .onChange(of: t.segments.count) {
                    withAnimation { proxy.scrollTo("live-bottom", anchor: .bottom) }
                }
            }
            askSection(t, live: true)
        }
        .background(Color(white: 0.07))
    }

    /// A saved exchange. The question leads and the answer is indented under
    /// it, so a column of these reads as a conversation rather than a stack
    /// of equal-weight paragraphs.
    private func qaCard(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(msg.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                // A hairline rule instead of an icon: it scales with the
                // answer and marks its extent, which a glyph cannot.
                Capsule().fill(Color.accentColor.opacity(0.5))
                    .frame(width: 2)
                Text(msg.answer)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    private func detailHeader(_ t: Transcript) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    Text(t.title).font(.system(size: 20, weight: .heavy)).foregroundStyle(.white)
                }
                HStack(spacing: 10) {
                    Text(dateText(t.startedAt)).foregroundStyle(.white.opacity(0.5))
                    Text(durationText(t.duration)).foregroundStyle(.white.opacity(0.5))
                    Text("\(t.speakers.count) \(t.speakers.count == 1 ? "person" : "people")")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .font(.system(size: 12))
            }
            Spacer()
            Button { model.toggleStar(t) } label: {
                Image(systemName: t.starred ? "star.fill" : "star")
                    .foregroundStyle(t.starred ? .yellow : .white.opacity(0.6))
            }.buttonStyle(.plain)
            Button { model.copy(t) } label: {
                Image(systemName: "doc.on.doc").foregroundStyle(.white.opacity(0.6))
            }.buttonStyle(.plain).help("Copy transcript")
            if model.recordingURL(for: t) != nil {
                Button { model.togglePlayback(t) } label: {
                    Image(systemName: model.playingRecording ? "stop.circle.fill" : "play.circle")
                        .foregroundStyle(model.playingRecording ? Color.accentColor : .white.opacity(0.6))
                }.buttonStyle(.plain)
                    .help(model.playingRecording ? "Stop playback" : "Play call recording")
            }
            Button { model.draftRecapEmail(t) } label: {
                if model.draftingRecap {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.recapCopied ? "checkmark.circle.fill" : "envelope")
                        .foregroundStyle(model.recapCopied ? .green : .white.opacity(0.6))
                }
            }.buttonStyle(.plain).disabled(model.draftingRecap)
                .help(model.recapCopied ? "Recap email copied!" : "Draft recap email (copies to clipboard)")
            Button { confirmDelete = true } label: {
                Image(systemName: "trash").foregroundStyle(.red.opacity(0.8))
            }.buttonStyle(.plain).help("Delete meeting")
            .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { model.deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("“\(t.title)” and its transcript will be permanently removed.")
            }
            Button { model.summarize(t) } label: {
                HStack(spacing: 6) {
                    if model.summarizing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "sparkles") }
                    Text(t.hasAI ? "Re-summarize" : "Summarize").font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.9)))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain).disabled(model.summarizing)
        }
        .padding(16)
    }

    private func tabBar(_ t: Transcript) -> some View {
        HStack(spacing: 20) {
            tab(.summary, "Summary")
            tab(.transcript, "Transcript")
            tab(.actions, "Action items", badge: t.actionItems?.count)
            tab(.analytics, "Analytics")
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func tab(_ tg: MeetingsModel.Tab, _ label: LocalizedStringKey, badge: Int? = nil) -> some View {
        Button { model.tab = tg } label: {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 14, weight: model.tab == tg ? .bold : .medium))
                    .foregroundStyle(model.tab == tg ? .white : .white.opacity(0.5))
                if let b = badge, b > 0 {
                    Text("\(b)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.8)))
                }
            }
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(model.tab == tg ? Color.accentColor : .clear).frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tabs

    @ViewBuilder private func summaryTab(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if let err = model.aiError {
                infoBox(err, color: .orange)
            }
            if let summary = t.summary {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                        Text("AI SUMMARY").font(.system(size: 11, weight: .bold)).tracking(0.8)
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(summary).font(.system(size: 15)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor.opacity(0.25), lineWidth: 1)))

                if let kp = t.keyPoints, !kp.isEmpty {
                    section("KEY POINTS") {
                        ForEach(kp, id: \.self) { bulletLine($0) }
                    }
                }
                if let chapters = t.chapters, !chapters.isEmpty {
                    section("CHAPTERS") {
                        ForEach(chapters) { chapterRow($0, in: t) }
                    }
                }
                if let d = t.decisions, !d.isEmpty {
                    section("DECISIONS") {
                        ForEach(d, id: \.self) { text in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.green.opacity(0.85))
                                    .padding(.top, 2)
                                Text(text).font(.system(size: 14)).foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                if let q = t.openQuestions, !q.isEmpty {
                    section("OPEN QUESTIONS") {
                        ForEach(q, id: \.self) { text in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange.opacity(0.85))
                                    .padding(.top, 2)
                                Text(text).font(.system(size: 14)).foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            } else {
                infoBox(MeetingAI_isAvailable
                        ? "Tap Summarize to generate an on-device AI summary, key points, and action items."
                        : (model.aiUnavailableReason ?? "On-device AI is unavailable on this Mac."),
                        color: .white.opacity(0.5))
            }

            section("TALK TIME") {
                ForEach(t.talkTime, id: \.speaker) { entry in
                    talkTimeRow(entry.speaker, entry.fraction, palette(t))
                        .contextMenu { renameMenu(t, speaker: entry.speaker) }
                }
                interactivityRow(t)
            }

            mentionsSection(t)

            if !t.chat.isEmpty {
                section("Q&A") {
                    ForEach(t.chat) { qaCard($0) }
                }
            }
        }
        .padding(18)
    }

    /// "Translate: Off / <language>" menu — targets come from the runtime
    /// query of Apple's on-device translation, never a hardcoded list.
    @ViewBuilder private var translateMenu: some View {
        if !model.supportedTargets.isEmpty {
            HStack(spacing: 8) {
                Spacer()
                if model.translating {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Translating…").font(.system(size: 11))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                } else if let note = model.translationNote {
                    Text(note).font(.system(size: 10))
                        .foregroundStyle(.orange.opacity(0.9)).lineLimit(1)
                }
                Menu {
                    Button {
                        model.captionTargetID = nil
                    } label: {
                        HStack {
                            Text("Off")
                            if model.captionTargetID == nil { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach(model.supportedTargets, id: \.id) { target in
                        Button {
                            model.captionTargetID = target.id
                        } label: {
                            HStack {
                                Text(target.name)
                                if model.captionTargetID == target.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "translate")
                            .font(.system(size: 11))
                        Text(model.captionTargetID.flatMap { id in
                            model.supportedTargets.first { $0.id == id }?.name
                        } ?? "Translate")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(model.captionTargetID == nil
                                     ? Color.white.opacity(0.55) : Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    @ViewBuilder private func transcriptTab(_ t: Transcript) -> some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 18) {
                translateMenu
                ForEach(t.ordered) { seg in
                    HStack(alignment: .top, spacing: 11) {
                        SpeakerAvatar(speaker: seg.speaker, size: 28, palette: palette(t))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(seg.speaker).font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(palette(t).color(seg.speaker))
                                Text(timestamp(seg.start)).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            Text(seg.text).font(.system(size: 14)).foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                            if let translated = model.translations[seg.id], !translated.isEmpty {
                                Text(translated).font(.system(size: 13))
                                    .italic()
                                    .foregroundStyle(Color.accentColor.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .id(seg.id)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(model.scrollTarget == seg.id
                                  ? Color.accentColor.opacity(0.14) : .clear))
                    .contextMenu { renameMenu(t, speaker: seg.speaker) }
                }
            }
            .padding(18)
            .onAppear {
                if let target = model.scrollTarget {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .onChange(of: model.scrollTarget) {
                if let target = model.scrollTarget {
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder private func actionsTab(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let items = t.actionItems, !items.isEmpty {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle").foregroundStyle(Color.accentColor).font(.system(size: 15))
                        Text(item.text).font(.system(size: 14)).foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let owner = item.owner {
                            HStack(spacing: 5) {
                                SpeakerAvatar(speaker: owner, size: 16, palette: palette(t))
                                Text(owner).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                    }
                }
            } else {
                infoBox(t.hasAI ? "No action items were found in this meeting."
                                : "Summarize the meeting to extract action items.",
                        color: .white.opacity(0.5))
            }
        }
        .padding(18)
    }

    // MARK: - Ask bar

    /// The answer panel plus the composer, as one block at the foot of the
    /// pane. Both live in the layout flow — the answer used to be an
    /// `.overlay`, and overlays take no space: a long answer covered the
    /// meeting behind it, ran off the top of the window, and could be
    /// neither scrolled nor dismissed.
    private func askSection(_ t: Transcript, live: Bool = false) -> some View {
        VStack(spacing: 0) {
            if model.askedQuestion != nil {
                Divider().overlay(Color.white.opacity(0.08))
                answerPanel()
            }
            composer(t, live: live)
        }
        .animation(.easeOut(duration: 0.18), value: model.askedQuestion)
    }

    /// The current exchange. The question stays pinned as the header while
    /// the answer scrolls beneath it: a long answer should never leave you
    /// wondering what you asked.
    @ViewBuilder private func answerPanel() -> some View {
        if let asked = model.askedQuestion {
            VStack(alignment: .leading, spacing: 0) {
                // Top-aligned, not baseline-aligned: an image has no text
                // baseline, so against a two-line question the controls got
                // pushed down into the padding.
                HStack(alignment: .top, spacing: 6) {
                    Text(asked)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    Spacer(minLength: 8)
                    if let a = model.answer {
                        Button { model.copyAnswer(a) } label: {
                            Text(model.answerCopied ? "Copied" : "Copy")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(model.answerCopied
                                                 ? .green : Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Copy this answer")
                    }
                    // A 10pt glyph with no padding is a 10×10 click target.
                    // Pad it out to a real one and give it a hit shape.
                    Button { model.clearAsk() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Close answer (Esc)")
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 9)

                answerBody()
            }
            .background(Color(white: 0.11))
        }
    }

    @ViewBuilder private func answerBody() -> some View {
        if model.asking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the transcript…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        } else if let error = model.askError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        } else if let a = model.answer {
            // Capped and internally scrollable: the answer is a guest in the
            // window, not the owner of it.
            ScrollView {
                Text(a)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
            .frame(maxHeight: 220)
        }
    }

    private func composer(_ t: Transcript, live: Bool = false) -> some View {
        let canSend = !model.question.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.asking
        return HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor.opacity(0.8))
            TextField(live ? "Ask about the meeting so far…" : "Ask anything about this meeting…",
                      text: $model.question)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white)
                .onSubmit { live ? model.askLive(t) : model.ask(t) }
            Button { live ? model.askLive(t) : model.ask(t) } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSend ? Color.accentColor : .white.opacity(0.22))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        .padding(14)
    }

    // MARK: - Meeting intelligence blocks

    /// A chapter: disclosure with a tappable timestamp chip that jumps the
    /// transcript to that moment.
    private func chapterRow(_ c: Chapter, in t: Transcript) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(c.bullets, id: \.self) { bulletLine($0) }
            }
            .padding(.top, 6)
            .padding(.leading, 2)
        } label: {
            HStack(spacing: 9) {
                Button { model.jump(to: c.startSeconds, in: t) } label: {
                    Text(timestamp(c.startSeconds))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("Jump to this moment in the transcript")
                Text(c.title).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .tint(.white.opacity(0.5))
    }

    /// Speaker switches per 10 minutes — a rough conversation-balance signal.
    @ViewBuilder private func interactivityRow(_ t: Transcript) -> some View {
        let ordered = t.ordered
        let switches = zip(ordered, ordered.dropFirst())
            .filter { $0.speaker != $1.speaker }.count
        let per10 = t.duration > 60
            ? Double(switches) / (t.duration / 600) : Double(switches)
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                .frame(width: 24)
            Text("Interactivity").font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white).frame(width: 90, alignment: .leading)
            Text("\(switches) turns · \(Int(per10.rounded()))/10 min")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            Spacer()
        }
    }

    /// Where other speakers said your name, with jump links.
    @ViewBuilder private func mentionsSection(_ t: Transcript) -> some View {
        let hits = t.mentions(of: model.userFirstName)
        if !hits.isEmpty {
            section("MENTIONS OF YOU") {
                ForEach(hits) { seg in
                    Button {
                        model.tab = .transcript
                        model.scrollTarget = seg.id
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Text(timestamp(seg.start))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(seg.speaker).font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(palette(t).color(seg.speaker))
                                Text(seg.text).font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.04)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Analytics tab (fillers, pace, monologues — on-device text math)

    @ViewBuilder private func analyticsTab(_ t: Transcript) -> some View {
        let a = model.analytics(for: t)
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                statCard("Duration", durationText(t.duration))
                statCard("Words", "\(a.totalWords)")
                statCard("Pace", paceText(a.meetingWPM))
            }
            section("BY SPEAKER") {
                ForEach(a.perSpeaker, id: \.speaker) { s in
                    speakerStatsCard(s, in: t)
                }
            }
            Text("Counted on-device from the transcript. Filler words are a heuristic — a trend to watch, not a verdict.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(18)
    }

    private func paceText(_ wpm: Double) -> String {
        wpm > 0 ? String(format: String(localized: "%d wpm"), Int(wpm.rounded())) : "—"
    }

    private func talkShareText(_ share: Double) -> String {
        String(format: String(localized: "%d%% of talk time"),
               Int((share * 100).rounded()))
    }

    private func statCard(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 20, weight: .heavy)).foregroundStyle(.white)
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    @ViewBuilder private func speakerStatsCard(_ s: SpeakingAnalytics.SpeakerStats,
                                               in t: Transcript) -> some View {
        let share = t.talkTime.first { $0.speaker == s.speaker }?.fraction ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SpeakerAvatar(speaker: s.speaker, size: 24, palette: palette(t))
                Text(s.speaker).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette(t).color(s.speaker))
                Spacer()
                Text(talkShareText(share))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            HStack(spacing: 22) {
                metric("Pace", paceText(s.wordsPerMinute))
                metric("Words", "\(s.words)")
                metric("Fillers", fillerText(s))
            }
            if s.longestMonologueSeconds >= 10 {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Text("Longest monologue: \(durationText(s.longestMonologueSeconds)) at \(timestamp(s.longestMonologueStart))")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    Button("Jump") { model.jump(to: s.longestMonologueStart, in: t) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .contextMenu { renameMenu(t, speaker: s.speaker) }
    }

    private func fillerText(_ s: SpeakingAnalytics.SpeakerStats) -> String {
        guard s.words > 0 else { return "—" }
        return "\(s.fillerCount) · \(String(format: "%.1f", s.fillerRate))/100"
    }

    private func metric(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - People

    /// Colours for this meeting's speakers, collisions resolved. Cheap
    /// enough to build per render — a handful of names and a dictionary.
    private func palette(_ t: Transcript) -> SpeakerPalette {
        SpeakerPalette(t.speakers)
    }

    /// Everyone in the meeting as a chip you can click to rename. This used
    /// to be a right-click context menu only, which meant the feature may as
    /// well not have existed — nobody discovers a hidden menu on a name.
    ///
    /// Its own full-width row rather than a line in the header: beside the
    /// header's buttons there was no room, and SwiftUI resolved that by
    /// wrapping each name one letter per line.
    private func peopleRow(_ t: Transcript) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(t.speakers, id: \.self) { speakerChip(t, speaker: $0) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
    }

    private func speakerChip(_ t: Transcript, speaker: String) -> some View {
        let editable = speaker != "You"
        let remembered = editable && model.isRemembered(speaker)
        return Button {
            beginRename(speaker, in: t)
        } label: {
            HStack(spacing: 5) {
                SpeakerAvatar(speaker: speaker, size: 18, palette: palette(t))
                Text(speaker).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    // Never wrap: a squeezed chip must clip or scroll, not
                    // stack its name vertically.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if remembered {
                    // ODE knows this voice and will label them automatically
                    // in future meetings.
                    Image(systemName: "waveform")
                        .font(.system(size: 9)).foregroundStyle(Color.accentColor)
                } else if editable {
                    Image(systemName: "pencil")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(editable ? 0.07 : 0.03)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!editable)
        .help(remembered ? "ODE remembers this voice — click to rename"
                         : (editable ? "Click to name this speaker" : "That's you"))
        .contextMenu { renameMenu(t, speaker: speaker) }
    }

    private func applyRename(rememberVoice: Bool) {
        if let old = renameTarget, let t = model.selected {
            model.renameSpeaker(in: t, from: old, to: renameText,
                                rememberVoice: rememberVoice)
        }
        renameTarget = nil
    }

    /// Open the rename sheet, prefilled: a real name is there to be edited,
    /// but "Speaker 2" is a placeholder you'd only have to clear.
    private func beginRename(_ speaker: String, in t: Transcript) {
        guard speaker != "You" else { return }
        renameTarget = speaker
        renameText = speaker.hasPrefix("Speaker ") ? "" : speaker
        renameHasVoice = model.hasVoiceSample(t, speaker: speaker)
    }

    /// Context-menu entry to rename a diarized speaker ("Speaker 1" → "Igor").
    @ViewBuilder private func renameMenu(_ t: Transcript, speaker: String) -> some View {
        if speaker != "You" {
            Button("Rename \"\(speaker)\"…") {
                renameTarget = speaker
                renameText = ""
            }
            if let attendees = t.attendees, !attendees.isEmpty {
                ForEach(attendees.filter { $0 != speaker }, id: \.self) { name in
                    Button("Rename to \(name)") {
                        model.renameSpeaker(in: t, from: speaker, to: name)
                    }
                }
            }
        }
    }

    // MARK: - Building blocks

    private func section<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(.white.opacity(0.4))
            content()
        }
    }

    private func bulletLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(.top, 6)
            Text(text).font(.system(size: 14)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func talkTimeRow(_ speaker: String, _ fraction: Double,
                             _ pal: SpeakerPalette) -> some View {
        HStack(spacing: 10) {
            SpeakerAvatar(speaker: speaker, size: 24, palette: pal)
            Text(speaker).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).frame(width: 70, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 7)
                    Capsule().fill(pal.color(speaker)).frame(width: max(6, geo.size.width * fraction), height: 7)
                }
            }.frame(height: 7)
            Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).frame(width: 40, alignment: .trailing)
        }
    }

    private func infoBox(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    private var MeetingAI_isAvailable: Bool { model.aiAvailable }

    // MARK: - Formatting

    private func dateText(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "d MMM yyyy · h:mm a"; return f.string(from: d) }
    private func timeText(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d) }
    private func durationText(_ t: TimeInterval) -> String { let m = Int(t)/60, s = Int(t)%60; return m > 0 ? "\(m)m" : "\(s)s" }
    private func timestamp(_ t: TimeInterval) -> String { String(format: "%02d:%02d", Int(t)/60, Int(t)%60) }
    private func previewLine(_ t: Transcript) -> String { t.ordered.first?.text ?? "No transcript" }
}

/// Hosts the Meetings view in a window.
final class MeetingNotesWindowController: NSWindowController {
    init(controller: ODEController? = nil, showLive: Bool = false) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "ODE — Meetings"
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: MeetingsView(controller: controller, showLive: showLive))
    }
    required init?(coder: NSCoder) { fatalError() }
}
