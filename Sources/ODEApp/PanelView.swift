import SwiftUI
import CoreAudio
import ODEKit

/// ODE glass control panel — voice cards + progressive disclosure.
/// Layout: header (status) · noise-cancellation cards · AUDIO rows ·
/// More options (echo, transcription, name) · Meetings row (live-aware) ·
/// pinned footer (Test + quit).
struct PanelView: View {
    @ObservedObject var controller: ODEController
    var onTest: () -> Void
    var onNotes: (_ showLive: Bool) -> Void
    var onQuit: () -> Void

    @AppStorage("ode.panelExpanded") private var expanded = false
    @State private var editingName = false
    @State private var nameDraft = UserDefaults.standard.string(forKey: "ode.userName") ?? ""

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                content
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.5)))
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
            } else {
                content.background(legacyGlassBackground)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 13) {
            header
            cardsSection
            audioSection
            if expanded { transcriptionSection }
            disclosureButton
            meetingsRow
            footer
        }
        .padding(18)
        .frame(width: 360)
    }

    // MARK: - Header

    /// One dynamic status line; the dot encodes it (green = active,
    /// blue = ready, gray = off).
    private var header: some View {
        HStack(spacing: 9) {
            Text("ODE")
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(.white)
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(controller.statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: Binding(get: { controller.masterOn },
                                     set: { _ in controller.toggleMaster() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.accentColor)
                .help("Turn both noise-cancellation paths on or off")
        }
    }

    private var statusColor: Color {
        if controller.anyActive { return .green }
        if controller.masterOn { return Color.accentColor }
        return .white.opacity(0.25)
    }

    // MARK: - Voice cards

    private var cardsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("NOISE CANCELLATION")
            HStack(spacing: 12) {
                voiceCard(
                    title: "You", subtitle: "Cancel my noise", icon: "mic.fill",
                    enabled: controller.micEnabled, active: controller.micActive,
                    installed: controller.virtualMicInstalled, level: controller.micLevel
                ) { controller.toggleMic() }
                voiceCard(
                    title: "Others", subtitle: "Cancel their noise", icon: "speaker.wave.2.fill",
                    enabled: controller.speakerEnabled, active: controller.speakerActive,
                    installed: controller.virtualSpeakerInstalled, level: controller.othersLevel
                ) { controller.toggleSpeaker() }
            }
        }
    }

    private func voiceCard(title: String, subtitle: String, icon: String,
                           enabled: Bool, active: Bool, installed: Bool, level: Float,
                           toggle: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            // Full card width so it always fits on one line.
            Text(installed ? subtitle : "Not installed")
                .font(.system(size: 11))
                .foregroundStyle(installed ? Color.white.opacity(0.45)
                                           : Color.orange.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 8)
            Spacer(minLength: 10)
            HStack(alignment: .bottom) {
                AudioMeter(level: level, active: active && enabled, color: .accentColor)
                Spacer()
                Toggle("", isOn: Binding(get: { enabled }, set: { _ in toggle() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.accentColor)
                    .scaleEffect(0.85)
            }
        }
        .padding(13)
        .frame(height: 118)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(enabled ? Color.accentColor.opacity(0.10) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(enabled ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.10),
                                lineWidth: 1))
        )
    }

    // MARK: - AUDIO section

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("AUDIO")
            settingRow(icon: "mic") {
                Text("Microphone").rowLabelStyle()
            } trailing: {
                DevicePicker(devices: controller.inputDevices,
                             selectedID: controller.selectedInputID,
                             fallback: "Default") { controller.selectInput($0) }
            }
            settingRow(icon: "speaker.wave.2") {
                Text("Speaker").rowLabelStyle()
            } trailing: {
                DevicePicker(devices: controller.outputDevices,
                             selectedID: controller.selectedOutputID,
                             fallback: "Default") { controller.selectOutput($0) }
            }
            if expanded {
                settingRow(icon: "wave.3.up",
                           hint: "Stops your mic from re-capturing what your speakers play, so the other side never hears themselves. When on, ODE uses the system default microphone.") {
                    Text("Echo cancellation").rowLabelStyle()
                } trailing: {
                    Toggle("", isOn: Binding(get: { controller.echoCancelEnabled },
                                             set: { _ in controller.toggleEchoCancel() }))
                        .toggleStyle(.switch).labelsHidden().tint(.accentColor)
                        .scaleEffect(0.85)
                }
            }
        }
    }

    // MARK: - TRANSCRIPTION section (expanded only)

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("TRANSCRIPTION")
            settingRow(icon: "doc.text",
                       hint: "Transcribes calls on-device and writes notes automatically when the meeting ends: summary, chapters, decisions and action items. Nothing leaves your Mac.") {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Meeting notes").rowLabelStyle()
                    Text(controller.transcribing ? "Transcribing…"
                         : "Transcribe & summarize on-device")
                        .font(.system(size: 10))
                        .foregroundStyle(controller.transcribing
                                         ? Color.red.opacity(0.9) : .white.opacity(0.4))
                }
            } trailing: {
                Toggle("", isOn: Binding(get: { controller.transcribeEnabled },
                                         set: { _ in controller.toggleTranscribe() }))
                    .toggleStyle(.switch).labelsHidden().tint(.accentColor)
                    .scaleEffect(0.85)
            }
            settingRow(icon: "cpu",
                       hint: "Speech-to-text engine. Parakeet detects the language automatically (excellent Spanish); Apple is the built-in system engine. Applies to the next meeting.") {
                Text("Model").rowLabelStyle()
            } trailing: {
                Menu {
                    ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                        Button {
                            controller.setEngine(engine)
                        } label: {
                            HStack {
                                Text(engine.displayName)
                                if controller.asrEngine == engine {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    rowValue(controller.asrEngine.displayName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            settingRow(icon: "person.2",
                       hint: "Tells remote participants apart, labeling them Speaker 1, 2… in transcripts. You can rename them afterwards. Downloads a model on first use.") {
                Text("Detect speakers").rowLabelStyle()
            } trailing: {
                Toggle("", isOn: Binding(get: { controller.detectSpeakers },
                                         set: { _ in controller.toggleDetectSpeakers() }))
                    .toggleStyle(.switch).labelsHidden().tint(.accentColor)
                    .scaleEffect(0.85)
            }
            settingRow(icon: "person.crop.circle",
                       hint: "Who \"You\" is in meeting notes — used for \"Mentions of you\" and so notes say your name instead of \"You\". Defaults to your macOS account name.") {
                Text("Your name").rowLabelStyle()
            } trailing: {
                Button { editingName = true } label: {
                    rowValue(displayName)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $editingName, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Used for \"Mentions of you\" and note attribution")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField(NSFullUserName(), text: $nameDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit { commitName() }
                        HStack {
                            Spacer()
                            Button("Save") { commitName() }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var displayName: String {
        let custom = UserDefaults.standard.string(forKey: "ode.userName") ?? ""
        return custom.isEmpty ? NSFullUserName() : custom
    }

    private func commitName() {
        UserDefaults.standard.set(nameDraft.trimmingCharacters(in: .whitespaces),
                                  forKey: "ode.userName")
        editingName = false
    }

    // MARK: - Disclosure

    private var disclosureButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(expanded ? "Fewer options" : "More options")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Meetings row (live-aware)

    @ViewBuilder private var meetingsRow: some View {
        if controller.transcribing, let live = controller.liveMeeting {
            // Live: red, elapsed ticker, jumps straight to live notes & Q&A.
            Button { onNotes(true) } label: {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.18))
                            .frame(width: 34, height: 34)
                        Circle().fill(Color.red).frame(width: 9, height: 9)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Meeting in progress")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Open live notes & Q&A")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsedText(since: live.startedAt))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.red.opacity(0.95))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.7))
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.red.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.red.opacity(0.35), lineWidth: 1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Button { onNotes(false) } label: {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 34, height: 34)
                        Image(systemName: "calendar")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Meetings")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Summaries, transcripts & actions")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if newCount > 0 {
                        Text("\(newCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.9)))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// New-notes badge (meetings saved since the window was last opened).
    /// Recomputed when the popover renders — cheap for a local store.
    private var newCount: Int { controller.newMeetingsCount() }

    private func elapsedText(since date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onTest) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                    Text("Test noise removal")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor.opacity(0.9)))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 46, height: 44)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.07)))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Quit ODE (virtual devices disappear until next launch)")
        }
    }

    // MARK: - Row building blocks

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
    }

    private func settingRow<L: View, T: View>(
        icon: String,
        hint: String? = nil,
        @ViewBuilder label: () -> L,
        @ViewBuilder trailing: () -> T
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 18)
            label()
            if let hint { HintRing(text: hint) }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 7)
    }

    private func rowValue(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    // MARK: - Legacy background

    private var legacyGlassBackground: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blending: .behindWindow)
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.72)],
                startPoint: .top, endPoint: .bottom)
        }
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

extension Text {
    fileprivate func rowLabelStyle() -> some View {
        self.font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
    }
}

/// A subtle ⓘ ring next to a setting label; click (or hover) explains what
/// the setting does in plain words.
private struct HintRing: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .padding(12)
                .frame(width: 240)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Compact device dropdown for a settings row: shows a shortened current
/// device name, opens a picker list. Redundant suffixes ("Microphone",
/// "Speakers") are stripped — the row label already says which is which.
struct DevicePicker: View {
    let devices: [AudioDevices.Device]
    let selectedID: AudioDeviceID?
    let fallback: String
    let onSelect: (AudioDeviceID) -> Void
    @State private var showing = false

    private var currentName: String {
        guard let dev = devices.first(where: { $0.id == selectedID }) else { return fallback }
        return Self.shorten(dev.name)
    }

    static func shorten(_ name: String) -> String {
        var n = name
        for suffix in [" Microphone", " Speakers", " Speaker", " Micrófono"] {
            if n.hasSuffix(suffix) { n = String(n.dropLast(suffix.count)); break }
        }
        return n
    }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                Text(currentName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(devices, id: \.id) { dev in
                    Button {
                        onSelect(dev.id); showing = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: dev.id == selectedID ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(dev.id == selectedID ? Color.accentColor : Color.secondary.opacity(0.5))
                            Text(dev.name)
                                .font(.system(size: 13))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if devices.isEmpty {
                    Text("No devices")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
            }
            .padding(6)
            .frame(width: 230)
        }
    }
}
