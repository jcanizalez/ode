import SwiftUI
import CoreAudio
import ODEKit

/// ODE glass control panel — card-based layout with live audio meters.
struct PanelView: View {
    @ObservedObject var controller: ODEController
    var onTest: () -> Void
    var onNotes: () -> Void
    var onQuit: () -> Void

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
        VStack(spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 8) {
                Text("NOISE CANCELLATION")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.4))
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
            HStack(spacing: 12) {
                DevicePicker(
                    label: "Microphone", current: controller.selectedInput?.name,
                    devices: controller.inputDevices, selectedID: controller.selectedInputID
                ) { controller.selectInput($0) }
                DevicePicker(
                    label: "Speaker", current: controller.selectedOutput?.name,
                    devices: controller.outputDevices, selectedID: controller.selectedOutputID
                ) { controller.selectOutput($0) }
            }
            transcriptsRow
            footer
        }
        .padding(18)
        .frame(width: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            Text("ODE")
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(.white)
            Circle()
                .fill(controller.anyActive ? Color.green : Color.white.opacity(0.25))
                .frame(width: 7, height: 7)
            Text(controller.anyActive ? "Active" : (controller.masterOn ? "Ready" : "Off"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Toggle("", isOn: Binding(get: { controller.masterOn },
                                     set: { _ in controller.toggleMaster() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.accentColor)
        }
    }

    // MARK: - Voice cards

    private func voiceCard(title: String, subtitle: String, icon: String,
                           enabled: Bool, active: Bool, installed: Bool, level: Float,
                           toggle: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Toggle("", isOn: Binding(get: { enabled }, set: { _ in toggle() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.accentColor)
                    .scaleEffect(0.85)
            }

            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 10)
            Text(installed ? subtitle : "Not installed")
                .font(.system(size: 11))
                .foregroundStyle(installed ? Color.white.opacity(0.45) : Color.orange.opacity(0.85))

            Spacer(minLength: 14)

            HStack(alignment: .bottom) {
                AudioMeter(level: level, active: active && enabled, color: .accentColor)
                Spacer()
                Text(enabled ? "On" : "Off")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(enabled ? Color.accentColor : Color.white.opacity(0.35))
            }
        }
        .padding(14)
        .frame(height: 150)
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

    // MARK: - Compact device pickers

    // MARK: - Transcripts row

    private var transcriptsRow: some View {
        HStack(spacing: 11) {
            Button(action: onNotes) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 34, height: 34)
                        Image(systemName: "doc.text")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("Transcripts")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                            if controller.transcribing {
                                Circle().fill(Color.red).frame(width: 6, height: 6)
                            }
                        }
                        Text(transcriptsSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Engine picker: Apple SpeechAnalyzer vs Parakeet v3. Applies to
            // the next transcription session.
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
                Divider()
                Button {
                    controller.toggleDetectSpeakers()
                } label: {
                    HStack {
                        Text("Detect speakers")
                        if controller.detectSpeakers {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Text(controller.asrEngine.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Toggle("", isOn: Binding(get: { controller.transcribeEnabled },
                                     set: { _ in controller.toggleTranscribe() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.accentColor)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)))
    }

    private var transcriptsSubtitle: String {
        if let p = controller.modelDownloadProgress {
            return "Downloading Parakeet model… \(Int(p * 100))%"
        }
        return controller.transcribing ? "Transcribing…" : "Save meeting transcripts"
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

/// A fully custom full-width device dropdown (Menu's borderless style refuses to
/// honor a custom box layout, so we use a Button + popover list instead).
struct DevicePicker: View {
    let label: String
    let current: String?
    let devices: [AudioDevices.Device]
    let selectedID: AudioDeviceID?
    let onSelect: (AudioDeviceID) -> Void
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(current ?? "Default")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)))
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
