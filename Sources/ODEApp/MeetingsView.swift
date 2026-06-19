import SwiftUI
import AppKit
import ODEKit

// Speaker avatar colors, matching the design language.
enum SpeakerStyle {
    static func color(_ speaker: String) -> Color {
        switch speaker.lowercased() {
        case "you":    return Color.accentColor
        case "others": return Color.orange
        default:
            // Stable hash → hue for any other label.
            let h = Double(abs(speaker.hashValue) % 360) / 360.0
            return Color(hue: h, saturation: 0.55, brightness: 0.85)
        }
    }
    static func initials(_ speaker: String) -> String {
        if speaker.caseInsensitiveCompare("you") == .orderedSame { return "Y" }
        if speaker.caseInsensitiveCompare("others") == .orderedSame { return "O" }
        return String(speaker.prefix(1)).uppercased()
    }
}

struct SpeakerAvatar: View {
    let speaker: String
    var size: CGFloat = 26
    var body: some View {
        ZStack {
            Circle().fill(SpeakerStyle.color(speaker))
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
    @StateObject private var model = MeetingsModel()
    @State private var confirmDelete = false

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
            detail.frame(minWidth: 480)
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(Color(white: 0.07))
        .onAppear { model.reload() }
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

    private func row(_ t: Transcript) -> some View {
        let selected = model.selectedID == t.id
        return Button { model.selectedID = t.id } label: {
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
                    ForEach(t.speakers.prefix(4), id: \.self) { SpeakerAvatar(speaker: $0, size: 18) }
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
        if let t = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(t)
                Divider().overlay(Color.white.opacity(0.08))
                tabBar(t)
                Divider().overlay(Color.white.opacity(0.08))
                ScrollView {
                    switch model.tab {
                    case .summary:  summaryTab(t)
                    case .transcript: transcriptTab(t)
                    case .actions:  actionsTab(t)
                    }
                }
                askBar(t)
            }
            .background(Color(white: 0.07))
        } else {
            Text("Select a meeting").foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(white: 0.07))
        }
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
                    HStack(spacing: -5) {
                        ForEach(t.speakers.prefix(4), id: \.self) { SpeakerAvatar(speaker: $0, size: 20) }
                    }
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
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func tab(_ tg: MeetingsModel.Tab, _ label: String, badge: Int? = nil) -> some View {
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
            } else {
                infoBox(MeetingAI_isAvailable
                        ? "Tap Summarize to generate an on-device AI summary, key points, and action items."
                        : (model.aiUnavailableReason ?? "On-device AI is unavailable on this Mac."),
                        color: .white.opacity(0.5))
            }

            section("TALK TIME") {
                ForEach(t.talkTime, id: \.speaker) { entry in talkTimeRow(entry.speaker, entry.fraction) }
            }

            if !t.chat.isEmpty {
                section("Q&A") {
                    ForEach(t.chat) { msg in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: "questionmark.circle.fill")
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                                Text(msg.question).font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 12)).foregroundStyle(Color.accentColor)
                                Text(msg.answer).font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                    }
                }
            }
        }
        .padding(18)
    }

    @ViewBuilder private func transcriptTab(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(t.ordered) { seg in
                HStack(alignment: .top, spacing: 11) {
                    SpeakerAvatar(speaker: seg.speaker, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(seg.speaker).font(.system(size: 13, weight: .bold))
                                .foregroundStyle(SpeakerStyle.color(seg.speaker))
                            Text(timestamp(seg.start)).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Text(seg.text).font(.system(size: 14)).foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(18)
    }

    @ViewBuilder private func actionsTab(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let items = t.actionItems, !items.isEmpty {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle").foregroundStyle(Color.accentColor).font(.system(size: 15))
                        Text(item).font(.system(size: 14)).foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
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

    private func askBar(_ t: Transcript) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor.opacity(0.8))
            TextField("Ask anything about this meeting…", text: $model.question)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white)
                .onSubmit { model.ask(t) }
            if model.asking { ProgressView().controlSize(.small) }
            Button { model.ask(t) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(Color.accentColor)
            }.buttonStyle(.plain).disabled(model.question.isEmpty || model.asking)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        .overlay(alignment: .top) {
            if let a = model.answer {
                Text(a).font(.system(size: 13)).foregroundStyle(.white)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13)))
                    .padding(.horizontal, 14).offset(y: -8).transition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
                    .alignmentGuide(.top) { $0[.bottom] }
            }
        }
        .padding(14)
    }

    // MARK: - Building blocks

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
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

    private func talkTimeRow(_ speaker: String, _ fraction: Double) -> some View {
        HStack(spacing: 10) {
            SpeakerAvatar(speaker: speaker, size: 24)
            Text(speaker).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).frame(width: 70, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 7)
                    Capsule().fill(SpeakerStyle.color(speaker)).frame(width: max(6, geo.size.width * fraction), height: 7)
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
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "ODE — Meetings"
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: MeetingsView())
    }
    required init?(coder: NSCoder) { fatalError() }
}
