import SwiftUI

/// The "Test how you'll sound" view — a three-step record/review flow.
struct ABTestView: View {
    @ObservedObject var model: ABTestModel

    var body: some View {
        VStack(spacing: 22) {
            headline
            Spacer(minLength: 0)
            centerControl
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: 460, height: 460)
        .background(background)
        .onDisappear { model.cleanup() }
    }

    // MARK: - Headline / subtitle per phase

    private var headline: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            switch model.phase {
            case .idle:
                Text("Press the mic and read the line below.")
                    .secondaryStyle()
            case .recording:
                VStack(spacing: 12) {
                    Text("Sample text to read while testing")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(model.sampleScript)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .processing:
                Text("Removing noise…").secondaryStyle()
            case .review:
                Text("Listen to your original recording and with ODE.")
                    .secondaryStyle()
            }
        }
    }

    private var title: String {
        switch model.phase {
        case .idle:       return "Test how you'll sound"
        case .recording:  return "Say something or read the script"
        case .processing: return "One sec…"
        case .review:     return "Hear how you'll sound"
        }
    }

    // MARK: - Center control per phase

    @ViewBuilder
    private var centerControl: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 14) {
                bigCircleButton(system: "mic.fill", tint: .white) {
                    model.startRecording()
                }
                Text("Press the mic to start")
                    .secondaryStyle()
            }
        case .recording:
            VStack(spacing: 12) {
                bigCircleButton(system: "stop.fill", tint: .red, recording: true) {
                    model.stopRecording()
                }
                Text("Recording").secondaryStyle()
                Text(model.elapsedText)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        case .processing:
            ProgressView()
                .controlSize(.large)
                .frame(width: 150, height: 150)
        case .review:
            reviewControls
        }
    }

    private var reviewControls: some View {
        VStack(spacing: 18) {
            // Off / On switch
            HStack(spacing: 12) {
                Text("Off")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.useDenoised ? .white.opacity(0.4) : .white)
                Toggle("", isOn: Binding(
                    get: { model.useDenoised },
                    set: { model.setUseDenoised($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.accentColor)
                Text("On")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.useDenoised ? .white : .white.opacity(0.4))
            }

            bigCircleButton(system: model.isPlaying ? "pause.fill" : "play.fill",
                            tint: .white) {
                model.togglePlay()
            }

            Button("Record again") { model.recordAgain() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .underline()

            if model.noiseReductionDB > 0.5 {
                Text(String(format: "ODE is ≈ %.0f dB quieter overall",
                            model.noiseReductionDB))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Group {
            if let err = model.errorText {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text("Your recording never leaves your device and isn't saved.")
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Building blocks

    private func bigCircleButton(system: String, tint: Color,
                                 recording: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        recording
                        ? AnyShapeStyle(Color.red.opacity(0.18))
                        : AnyShapeStyle(LinearGradient(
                            colors: [Color.white.opacity(0.95), Color(white: 0.82)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .frame(width: 150, height: 150)
                    .overlay(
                        Circle().stroke(
                            recording ? Color.red.opacity(0.6) : Color.white.opacity(0.25),
                            lineWidth: recording ? 4 : 1))
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                Image(systemName: system)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(recording ? Color.red : Color.black.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
    }

    private var background: some View {
        Group {
            if #available(macOS 26.0, *) {
                Color.black.opacity(0.5).glassEffect(.regular, in: .rect(cornerRadius: 0))
            } else {
                ZStack {
                    VisualEffectBackground(material: .hudWindow, blending: .behindWindow)
                    Color.black.opacity(0.55)
                }
            }
        }
        .ignoresSafeArea()
    }
}

private extension Text {
    func secondaryStyle() -> some View {
        self.font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.55))
            .multilineTextAlignment(.center)
    }
}
