import SwiftUI
import CoreAudio
import ODEKit

/// Observable state bridging the SwiftUI panel to the ODE engine.
///
/// The toggle is only a *setting* (`isEnabled`). The engine actually captures
/// the real microphone and denoises **only when an app opens the ODE virtual
/// microphone** — so there is no recording indicator when idle.
///
/// Conceptually: ODE always *outputs* to the "ODE Microphone" virtual device;
/// the user only chooses which real **input** microphone to capture from.
final class ODEController: ObservableObject {
    /// User setting: is noise cancellation armed?
    @Published var isEnabled = false
    /// Is the engine actively processing right now (an app is using the mic)?
    @Published var isActive = false
    /// Real input microphones the user can capture from.
    @Published var inputDevices: [AudioDevices.Device] = []
    /// The chosen real input mic.
    @Published var selectedInputID: AudioDeviceID?

    private let engine = LiveEngine()
    private var usageObserver: AudioDevices.UsageObserver?

    init() {
        refreshDevices()
        selectedInputID = preferredInputDevice()?.id
        installUsageObserver()
    }

    deinit {
        if let o = usageObserver { AudioDevices.removeUsageObserver(o) }
    }

    /// The fixed virtual output device ("ODE Microphone"). ODE always writes
    /// denoised audio here; apps select it as their microphone.
    var virtualMic: AudioDevices.Device? {
        let outs = AudioDevices.all().filter { $0.hasOutput }
        return outs.first { $0.name.localizedCaseInsensitiveContains("ode microphone") }
            ?? outs.first { $0.name.localizedCaseInsensitiveContains("blackhole") }
    }

    var virtualMicInstalled: Bool { virtualMic != nil }

    var selectedInput: AudioDevices.Device? {
        inputDevices.first { $0.id == selectedInputID }
    }

    var statusText: String {
        if !virtualMicInstalled { return "Install the ODE Microphone to begin" }
        if isActive {
            return isEnabled ? "Removing noise" : "Passing through (noise on)"
        }
        return isEnabled ? "On · waiting for a call" : "Off · waiting for a call"
    }

    func refreshDevices() {
        // Only real microphones — never the virtual ODE Microphone / loopbacks.
        inputDevices = AudioDevices.all().filter { $0.hasInput && !isLoopback($0) }
        if selectedInputID == nil || !inputDevices.contains(where: { $0.id == selectedInputID }) {
            selectedInputID = preferredInputDevice()?.id
        }
    }

    /// Flip the noise-cancellation setting. Audio keeps flowing either way;
    /// this only switches between denoised and raw passthrough.
    func toggle() {
        isEnabled.toggle()
        engine.bypassDenoise = !isEnabled
        reconcile()
    }

    func selectInput(_ id: AudioDeviceID) {
        selectedInputID = id
        if isActive {            // re-capture from the newly chosen mic
            engine.stop()
            isActive = false
        }
        reconcile()
    }

    func stopIfRunning() {
        if isActive { engine.stop(); isActive = false }
    }

    // MARK: - Usage gating

    private func installUsageObserver() {
        if let o = usageObserver { AudioDevices.removeUsageObserver(o); usageObserver = nil }
        guard let dev = virtualMic else { return }
        usageObserver = AudioDevices.addUsageObserver(dev.id) { [weak self] _ in
            DispatchQueue.main.async { self?.reconcile() }
        }
    }

    /// Start or stop the engine so that audio flows whenever an app is using the
    /// ODE Microphone. The "Cancel my noise" toggle only switches between
    /// denoised and raw passthrough — it never silences the mic.
    private func reconcile() {
        guard let out = virtualMic else { return }
        let inUse = AudioDevices.isInputInUse(out.id)

        if inUse && !isActive {
            guard let input = selectedInput, input.id != out.id else {
                NSLog("ODE: no valid input microphone selected.")
                return
            }
            do {
                try engine.start(inputDevice: input, outputDevice: out, bypass: !isEnabled)
                isActive = true
            } catch {
                isActive = false
                NSLog("ODE: failed to start engine: \(error.localizedDescription)")
            }
        } else if !inUse && isActive {
            engine.stop()
            isActive = false
        } else if isActive {
            // Already running — just keep bypass in sync with the toggle.
            engine.bypassDenoise = !isEnabled
        }
    }

    private func preferredInputDevice() -> AudioDevices.Device? {
        if let def = AudioDevices.defaultInput(), !isLoopback(def), def.hasInput {
            return def
        }
        return inputDevices.first
    }

    private func isLoopback(_ d: AudioDevices.Device) -> Bool {
        let n = d.name.lowercased()
        return n.contains("ode microphone") || n.contains("blackhole")
    }
}
