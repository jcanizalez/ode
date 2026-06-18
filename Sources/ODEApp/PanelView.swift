import SwiftUI
import CoreAudio
import ODEKit

/// Krisp-style glass control panel for ODE.
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
            noiseCard
            deviceCard
            footer
        }
        .padding(18)
        .frame(width: 320)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(controller.isActive
                          ? Color.accentColor.opacity(0.9)
                          : Color.white.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(controller.isActive ? Color.white : Color.white.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("ODE")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white)
                Text(controller.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(controller.isActive
                                     ? Color.accentColor
                                     : Color.white.opacity(0.45))
            }
            Spacer()
        }
    }

    private var noiseCard: some View {
        card {
            sectionTitle("Noise Cancellation")
            Toggle(isOn: Binding(
                get: { controller.isEnabled },
                set: { _ in controller.toggle() })
            ) {
                Text("Cancel my noise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            .toggleStyle(.switch)
            .tint(.accentColor)
        }
    }

    private var deviceCard: some View {
        card {
            sectionTitle("ODE Microphone")
            Menu {
                let currentID = controller.selectedOutputID
                ForEach(controller.outputDevices, id: \.id) { dev in
                    Button {
                        controller.selectOutput(dev.id)
                    } label: {
                        if dev.id == currentID {
                            Label(dev.name, systemImage: "checkmark")
                        } else {
                            Text(dev.name)
                        }
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(controller.selectedOutput?.name ?? "Select output…")
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
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onTest) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                    Text("Test · Before / After")
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
