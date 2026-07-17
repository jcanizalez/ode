import AppKit
import SwiftUI
import ODEKit

/// The Settings window — everything you set once lives here, so the menu-bar
/// popover stays a slim cockpit. Sidebar panes follow macOS convention.
final class SettingsWindowController: NSWindowController {
    convenience init(controller: ODEController,
                     autoCheckUpdates: Binding<Bool>,
                     onCheckUpdates: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "ODE Settings"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(
            controller: controller,
            autoCheckUpdates: autoCheckUpdates,
            onCheckUpdates: onCheckUpdates))
        self.init(window: window)
    }
}

// MARK: - Panes

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, audio, transcription, updates, about
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .audio: return "Audio"
        case .transcription: return "Transcription"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .audio: return "mic"
        case .transcription: return "doc.text"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

/// Noise-strength presets shown to the user; the raw 0...1 value is what's
/// stored, so a future slider stays compatible.
enum NoiseStrengthPreset: CaseIterable {
    case high, medium, low

    var value: Double {
        switch self {
        case .high: return 1.0
        case .medium: return 0.75
        case .low: return 0.5
        }
    }

    var displayName: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    static func nearest(to value: Double) -> NoiseStrengthPreset {
        allCases.min { abs($0.value - value) < abs($1.value - value) } ?? .high
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var controller: ODEController
    var autoCheckUpdates: Binding<Bool>
    var onCheckUpdates: () -> Void

    @State private var pane: SettingsPane = .general
    @State private var nameDraft = UserDefaults.standard.string(forKey: "ode.userName") ?? ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detail
        }
        .frame(width: 720, height: 460)
        .background(Color(red: 0.09, green: 0.10, blue: 0.12))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Spacer().frame(height: 34)  // room for the transparent titlebar
            ForEach(SettingsPane.allCases) { p in
                Button {
                    pane = p
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: p.icon)
                            .font(.system(size: 13))
                            .frame(width: 20)
                        Text(p.title)
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(pane == p ? Color.white : .white.opacity(0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(pane == p ? Color.accentColor.opacity(0.85) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 185)
        .background(Color.black.opacity(0.25))
    }

    // MARK: Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(pane.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text(paneSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 4)
                switch pane {
                case .general: generalPane
                case .audio: audioPane
                case .transcription: transcriptionPane
                case .updates: updatesPane
                case .about: aboutPane
                }
                Spacer(minLength: 0)
            }
            .padding(26)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var paneSubtitle: LocalizedStringKey {
        switch pane {
        case .general: return "How ODE lives on your Mac."
        case .audio: return "Processing options for your microphone and speaker."
        case .transcription: return "How meetings are transcribed and attributed."
        case .updates: return "ODE keeps itself current — quietly."
        case .about: return "On-device noise cancellation & meeting notes."
        }
    }

    /// A card that groups related setting rows, like the mock.
    private func card<C: View>(@ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)))
    }

    // MARK: General

    private var generalPane: some View {
        card {
            settingRow(icon: "power",
                       hint: "Starts ODE automatically when you log in, so the virtual devices are always ready before your first call.") {
                Text("Launch at login").rowLabelStyle()
            } trailing: {
                settingToggle(isOn: controller.launchAtLogin) { controller.toggleLaunchAtLogin() }
            }
            settingRow(icon: "keyboard",
                       hint: "Toggles noise cancellation from anywhere — even mid-call with another app focused.") {
                Text("Noise cancellation shortcut").rowLabelStyle()
            } trailing: {
                Text("⌃⌥⌘O")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
        }
    }

    // MARK: Audio

    private var audioPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                settingRow(icon: "wave.3.up",
                           hint: "Experimental — currently unreliable and can leave your mic silent; leave off unless testing. Stops your mic from re-capturing speaker sound. AirPods and most headsets do their own echo cancellation, so they don't need this.") {
                    HStack(spacing: 6) {
                        Text("Echo cancellation").rowLabelStyle()
                        Text("EXPERIMENTAL")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(.orange.opacity(0.9))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                } trailing: {
                    settingToggle(isOn: controller.echoCancelEnabled) { controller.toggleEchoCancel() }
                }
                settingRow(icon: "music.mic",
                           hint: "High-pass, warmth and presence EQ, gentle compression and a safety limiter — applied to your mic after noise removal, on-device. One broadcast-ready preset; flips instantly, even mid-call.") {
                    Text("Studio Voice").rowLabelStyle()
                } trailing: {
                    settingToggle(isOn: controller.studioVoiceEnabled) { controller.toggleStudioVoice() }
                }
                settingRow(icon: "dial.medium",
                           hint: "How much noise to remove. Lower keeps voices more natural by blending some of the original sound back in. Applies instantly, even mid-call.") {
                    Text("Noise suppression strength").rowLabelStyle()
                } trailing: {
                    Menu {
                        ForEach(NoiseStrengthPreset.allCases, id: \.self) { preset in
                            Button {
                                controller.setNoiseStrength(preset.value)
                            } label: {
                                HStack {
                                    Text(preset.displayName)
                                    if NoiseStrengthPreset.nearest(to: controller.noiseStrength) == preset {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        rowValue(NoiseStrengthPreset.nearest(to: controller.noiseStrength).displayName)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            sectionLabel("PRIVACY")
                .padding(.top, 6)
            card {
                settingRow(icon: "eye.slash",
                           hint: "Keeps ODE's windows out of screen shares, recordings and screenshots — you still see them, your audience doesn't.") {
                    Text("Hide from screen sharing").rowLabelStyle()
                } trailing: {
                    settingToggle(isOn: controller.hideFromCapture) { controller.toggleHideFromCapture() }
                }
            }
        }
    }

    // MARK: Transcription

    private var transcriptionPane: some View {
        card {
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
                settingToggle(isOn: controller.detectSpeakers) { controller.toggleDetectSpeakers() }
            }
            settingRow(icon: "record.circle",
                       hint: "Saves each meeting's audio (both sides, denoised) next to its transcript — on this Mac only, never uploaded. Applies from the next meeting. Recording laws vary; let participants know.") {
                Text("Record meeting audio").rowLabelStyle()
            } trailing: {
                settingToggle(isOn: controller.recordMeetingAudio) { controller.toggleRecordMeetingAudio() }
            }
            settingRow(icon: "person.crop.circle",
                       hint: "Who \"You\" is in meeting notes — used for \"Mentions of you\" and so notes say your name instead of \"You\". Defaults to your macOS account name.") {
                Text("Your name").rowLabelStyle()
            } trailing: {
                TextField(NSFullUserName(), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .onSubmit { commitName() }
                    .onChange(of: nameDraft) { _, _ in commitName() }
            }
        }
    }

    private func commitName() {
        UserDefaults.standard.set(nameDraft.trimmingCharacters(in: .whitespaces),
                                  forKey: "ode.userName")
    }

    // MARK: Updates

    private var updatesPane: some View {
        card {
            settingRow(icon: "shippingbox") {
                Text("Current version").rowLabelStyle()
            } trailing: {
                Text("v\(appVersion)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            settingRow(icon: "arrow.triangle.2.circlepath",
                       hint: "Checks the update feed and installs new versions in place — signed and verified.") {
                Text("Check for updates").rowLabelStyle()
            } trailing: {
                Button("Check now") { onCheckUpdates() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            settingRow(icon: "clock.arrow.circlepath",
                       hint: "Looks for new versions in the background, roughly once a day.") {
                Text("Check automatically").rowLabelStyle()
            } trailing: {
                Toggle("", isOn: autoCheckUpdates)
                    .toggleStyle(.switch).labelsHidden().tint(.accentColor)
                    .scaleEffect(0.85)
            }
        }
    }

    // MARK: About

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ODE")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Version \(appVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Text("On-device noise cancellation & meeting notes.\nNothing you say ever leaves your Mac.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.7))
            Link("github.com/jcanizalez/ode",
                 destination: URL(string: "https://github.com/jcanizalez/ode")!)
                .font(.system(size: 12.5, weight: .medium))
            Text("Open source under the MIT license.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
