import SwiftUI
import CoreAudio
import ODEKit

/// Glass control panel for ODE — editorial-precision layout.
struct PanelView: View {
    @ObservedObject var controller: ODEController
    var onTest: () -> Void
    var onNotes: () -> Void
    var onQuit: () -> Void

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                content
                    .background(
                        RoundedRectangle(cornerRadius: 22)
                            .fill(Color.black.opacity(0.5))
                    )
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
            } else {
                content.background(legacyGlassBackground)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            voiceTiles
            devicesBlock
            meetingsRow
            footer
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        let denoising = (controller.micActive && controller.micEnabled)
            || (controller.speakerActive && controller.speakerEnabled)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("ODE")
                .font(.system(size: 22, weight: .black))
                .tracking(6)
                .foregroundStyle(.white)
            Text("·")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.25))
            Text(controller.statusText.lowercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(denoising
                                 ? Color.accentColor.opacity(0.95)
                                 : Color.white.opacity(0.4))
            Spacer()
        }
        .padding(.bottom, 2)
    }

    // MARK: - Voice tiles  (replaces stacked toggles)

    private var voiceTiles: some View {
        HStack(spacing: 0) {
            voiceTile(
                label: "YOU",
                enabled: controller.micEnabled,
                active: controller.micActive,
                installed: controller.virtualMicInstalled
            ) { controller.toggleMic() }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            voiceTile(
                label: "OTHERS",
                enabled: controller.speakerEnabled,
                active: controller.speakerActive,
                installed: controller.virtualSpeakerInstalled
            ) { controller.toggleSpeaker() }
        }
        .frame(height: 96)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    /// One half of the noise-cancellation tile.
    private func voiceTile(label: String,
                           enabled: Bool,
                           active: Bool,
                           installed: Bool,
                           action: @escaping () -> Void) -> some View {
        let state: TileState = !installed
            ? .unavailable
            : (active && enabled ? .denoising
               : (active ? .passthrough
                  : (enabled ? .armed : .off)))

        return Button(action: action) {
            VStack(spacing: 9) {
                Text(label)
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.55))

                ZStack {
                    Circle()
                        .stroke(state.ringColor, lineWidth: 1.2)
                        .frame(width: 22, height: 22)
                    Circle()
                        .fill(state.fillColor)
                        .frame(width: state.dotSize, height: state.dotSize)
                }

                Text(state.caption)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(state.captionColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private enum TileState {
        case denoising, passthrough, armed, off, unavailable

        var caption: String {
            switch self {
            case .denoising: return "denoising"
            case .passthrough: return "passthrough"
            case .armed: return "armed"
            case .off: return "off"
            case .unavailable: return "not installed"
            }
        }
        var ringColor: Color {
            switch self {
            case .denoising: return Color.accentColor.opacity(0.85)
            case .passthrough: return Color.white.opacity(0.45)
            case .armed: return Color.accentColor.opacity(0.55)
            case .off: return Color.white.opacity(0.18)
            case .unavailable: return Color.orange.opacity(0.55)
            }
        }
        var fillColor: Color {
            switch self {
            case .denoising: return Color.accentColor
            case .passthrough: return Color.white.opacity(0.55)
            case .armed: return Color.accentColor.opacity(0.35)
            case .off: return Color.clear
            case .unavailable: return Color.orange.opacity(0.7)
            }
        }
        var dotSize: CGFloat {
            switch self {
            case .denoising, .passthrough, .unavailable: return 10
            case .armed: return 6
            case .off: return 0
            }
        }
        var captionColor: Color {
            switch self {
            case .denoising: return Color.accentColor
            case .passthrough: return Color.white.opacity(0.6)
            case .armed: return Color.white.opacity(0.55)
            case .off: return Color.white.opacity(0.35)
            case .unavailable: return Color.orange.opacity(0.85)
            }
        }
    }

    // MARK: - Devices  (one compact row each)

    private var devicesBlock: some View {
        VStack(spacing: 8) {
            deviceRow(
                tag: "MIC IN",
                icon: "mic.fill",
                inUse: controller.micActive,
                installed: controller.virtualMicInstalled,
                current: controller.selectedInput?.name,
                placeholder: "Select a microphone",
                devices: controller.inputDevices,
                selectedID: controller.selectedInputID,
                onSelect: { controller.selectInput($0) }
            )
            deviceRow(
                tag: "OUT",
                icon: "speaker.wave.2.fill",
                inUse: controller.speakerActive,
                installed: controller.virtualSpeakerInstalled,
                current: controller.selectedOutput?.name,
                placeholder: "Select an output",
                devices: controller.outputDevices,
                selectedID: controller.selectedOutputID,
                onSelect: { controller.selectOutput($0) }
            )
        }
    }

    private func deviceRow(tag: String,
                           icon: String,
                           inUse: Bool,
                           installed: Bool,
                           current: String?,
                           placeholder: String,
                           devices: [AudioDevices.Device],
                           selectedID: AudioDeviceID?,
                           onSelect: @escaping (AudioDeviceID) -> Void) -> some View {
        Menu {
            ForEach(devices, id: \.id) { dev in
                Button {
                    onSelect(dev.id)
                } label: {
                    if dev.id == selectedID {
                        Label(dev.name, systemImage: "checkmark")
                    } else {
                        Text(dev.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                // status dot — collapses to nothing when not installed
                Circle()
                    .fill(installed
                          ? (inUse ? Color.green : Color.white.opacity(0.22))
                          : Color.orange.opacity(0.7))
                    .frame(width: 6, height: 6)

                Text(tag)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 42, alignment: .leading)

                Text(current ?? placeholder)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(current == nil ? Color.white.opacity(0.4) : Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Meetings (its own slim row)

    private var meetingsRow: some View {
        Button(action: { controller.toggleTranscribe() }) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(
                            controller.transcribing
                                ? Color.red.opacity(0.85)
                                : (controller.transcribeEnabled
                                   ? Color.accentColor.opacity(0.65)
                                   : Color.white.opacity(0.2)),
                            lineWidth: 1.2)
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(controller.transcribing
                              ? Color.red
                              : (controller.transcribeEnabled
                                 ? Color.accentColor
                                 : Color.clear))
                        .frame(width: 6, height: 6)
                }

                Text("MEETINGS")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))

                Text(meetingCaption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(meetingCaptionColor)

                Spacer()

                Text(controller.transcribeEnabled ? "on" : "off")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(controller.transcribeEnabled
                                     ? Color.accentColor
                                     : Color.white.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var meetingCaption: String {
        if controller.transcribing { return "transcribing…" }
        if controller.transcribeEnabled { return "armed · waiting for a call" }
        return "transcripts off"
    }
    private var meetingCaptionColor: Color {
        if controller.transcribing { return Color.red.opacity(0.9) }
        if controller.transcribeEnabled { return Color.white.opacity(0.7) }
        return Color.white.opacity(0.4)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onTest) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                        Text("Test the ODE magic")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.9))
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button(action: onQuit) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Quit ODE")
            }

            Button(action: onNotes) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                    Text("Meeting Notes")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
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
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}
