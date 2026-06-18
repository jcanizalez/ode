import SwiftUI
import AppKit
import ODEKit

/// Meeting Notes browser — editorial layout: numbered chapters on the left,
/// manuscript-style transcript on the right.
struct MeetingNotesView: View {
    @State private var transcripts: [Transcript] = []
    @State private var selectedID: Transcript.ID?

    private var selected: Transcript? { transcripts.first { $0.id == selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            list
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
            detail
        }
        .frame(width: 760, height: 500)
        .background(background)
        .onAppear(perform: reload)
    }

    // MARK: - List (left rail)

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            listHeader
            if transcripts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(transcripts.enumerated()), id: \.element.id) { idx, t in
                            listRow(index: idx + 1, t: t)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 260)
    }

    private var listHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MEETING")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.4))
                Text("Notes")
                    .font(.system(size: 22, weight: .black))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
            }
            Spacer()
            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(7)
                    .background(Circle().fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("Reload")
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.path")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.white.opacity(0.18))
            VStack(spacing: 4) {
                Text("No meetings yet")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Enable Transcribe and join a call.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private func listRow(index: Int, t: Transcript) -> some View {
        let isSelected = selectedID == t.id
        return Button {
            selectedID = t.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(String(format: "%02d", index))
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(isSelected
                                     ? Color.accentColor
                                     : Color.white.opacity(0.3))
                    .frame(width: 22, alignment: .leading)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(dateText(t.startedAt)) · \(durationText(t.duration))")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(isSelected ? Color.white.opacity(0.05) : Color.clear)
                    if isSelected {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2)
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail (right page)

    private var detail: some View {
        Group {
            if let t = selected {
                VStack(alignment: .leading, spacing: 0) {
                    detailHeader(t)
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(t.ordered) { seg in
                                segmentRow(seg)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                    }
                }
            } else {
                detailPlaceholder
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func detailHeader(_ t: Transcript) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.title)
                    .font(.system(size: 18, weight: .black))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                Text("\(dateText(t.startedAt)) · \(durationText(t.duration))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            HStack(spacing: 4) {
                detailActionButton(icon: "doc.on.doc", help: "Copy transcript") { copyText(t) }
                detailActionButton(icon: "folder", help: "Show files in Finder") { revealInFinder(t) }
                detailActionButton(icon: "trash", help: "Delete", tint: .red) { delete(t) }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func detailActionButton(icon: String, help: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.04)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var detailPlaceholder: some View {
        VStack(spacing: 8) {
            Text("Select a meeting")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Text("Choose a transcript from the list.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func segmentRow(_ seg: TranscriptSegment) -> some View {
        let isYou = seg.speaker == "You"
        let accent: Color = isYou ? Color.accentColor : Color.orange
        return HStack(alignment: .top, spacing: 16) {
            Text(timestamp(seg.start))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 40, alignment: .leading)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(seg.speaker.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(accent.opacity(0.95))
                Text(seg.text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private func reload() {
        transcripts = TranscriptStore.shared.load()
        if selectedID == nil { selectedID = transcripts.first?.id }
    }

    private func delete(_ t: Transcript) {
        TranscriptStore.shared.delete(t)
        reload()
    }

    private func copyText(_ t: Transcript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.plainText(), forType: .string)
    }

    private func revealInFinder(_ t: Transcript) {
        NSWorkspace.shared.activateFileViewerSelecting([TranscriptStore.shared.directory])
    }

    // MARK: - Formatting

    private func dateText(_ d: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        return df.string(from: d)
    }
    private func durationText(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
    private func timestamp(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private var background: some View {
        Group {
            if #available(macOS 26.0, *) {
                Color.black.opacity(0.6)
            } else {
                Color.black.opacity(0.65)
            }
        }.ignoresSafeArea()
    }
}

/// Hosts the Meeting Notes view in a window.
final class MeetingNotesWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Meeting Notes"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: MeetingNotesView())
    }
    required init?(coder: NSCoder) { fatalError() }
}
