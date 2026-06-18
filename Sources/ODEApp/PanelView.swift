import SwiftUI
import CoreAudio
import ODEKit

/// Glass control panel for ODE.
struct PanelView: View {
    @ObservedObject var controller: ODEController
    var onTest: () -> Void
    var onQuit: () -> Void

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                content
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.black.opacity(0.45))
                    )
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            } else {
                content.background(legacyGlassBackground)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            noiseCancellationCard
            devicesCard
            footer
        }
        .padding(18)
        .frame(width: 320)
    }

    // MARK: - Sections

    private var header: some View {
        let denoising = (controller.micActive && controller.micEnabled)
            || (controller.speakerActive && controller.speakerEnabled)
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(denoising
                          ? Color.accentColor.opacity(0.9)
                          : Color.white.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(denoising ? Color.white : Color.white.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("ODE")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white)
                Text(controller.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(denoising ? Color.accentColor : Color.white.opacity(0.45))
            }
            Spacer()
        }
    }

    /// Section 1 — just the enable/disable toggles.
    private var noiseCancellationCard: some View {
        card {
            sectionTitle("Noise Cancellation")
            toggleRow(title: "Cancel my noise",
                      isOn: controller.micEnabled) { controller.toggleMic() }
            toggleRow(title: "Cancel others' noise",
                      isOn: controller.speakerEnabled) { controller.toggleSpeaker() }
        }
    }

    /// Section 2 — choose the real devices ODE bridges to/from, with live status.
    private var devicesCard: some View {
        card {
            sectionTitle("ODE Devices")

            deviceLabel(title: "ODE Microphone",
                        installed: controller.virtualMicInstalled,
                        inUse: controller.micActive)
            devicePicker(
                icon: "mic.fill",
                placeholder: "Select a microphone…",
                current: controller.selectedInput?.name,
                devices: controller.inputDevices,
                selectedID: controller.selectedInputID) { controller.selectInput($0) }

            deviceLabel(title: "ODE Speaker",
                        installed: controller.virtualSpeakerInstalled,
                        inUse: controller.speakerActive)
                .padding(.top, 2)
            devicePicker(
                icon: "speaker.wave.2.fill",
                placeholder: "Select an output…",
                current: controller.selectedOutput?.name,
                devices: controller.outputDevices,
                selectedID: controller.selectedOutputID) { controller.selectOutput($0) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onTest) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("Test the ODE magic")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.opacity(0.85)))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.white.opacity(0.08)))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Building blocks

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.45))
    }

    private func toggleRow(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .toggleStyle(.switch)
        .tint(.accentColor)
    }

    private func devicePicker(icon: String, placeholder: String, current: String?,
                              devices: [AudioDevices.Device], selectedID: AudioDeviceID?,
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
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                Text(current ?? placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    /// A device row label with a live usage indicator (in use vs idle), matching
    /// the reference "Used by …" / "Not selected" affordance.
    private func deviceLabel(title: String, installed: Bool, inUse: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            if !installed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.85))
                Text("not installed")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.85))
            } else {
                Circle()
                    .fill(inUse ? Color.green : Color.white.opacity(0.25))
                    .frame(width: 7, height: 7)
                Text(inUse ? "In use" : "Idle")
                    .font(.system(size: 11))
                    .foregroundStyle(inUse ? Color.green : Color.white.opacity(0.4))
            }
            Spacer()
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18),
                                         Color.white.opacity(0.06),
                                         Color.white.opacity(0.18)],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1))
        )
    }

    private var legacyGlassBackground: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blending: .behindWindow)
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
