import SwiftUI
import CoreAudio
import ODEKit

/// Observable state bridging the SwiftUI panel to the ODE engine.
///
/// The toggle is only a *setting* (`isEnabled`). The engine actually captures
/// the real microphone and denoises **only when an app opens the ODE virtual
/// microphone** — so there is no recording indicator when idle, just like Krisp.
final class ODEController: ObservableObject {
    /// User setting: is noise cancellation armed?
    @Published var isEnabled = false
    /// Is the engine actively processing right now (an app is using the mic)?
    @Published var isActive = false
    @Published var outputDevices: [AudioDevices.Device] = []
    @Published var selectedOutputID: AudioDeviceID?

    private let engine = LiveEngine()
    private var usageObserver: AudioDevices.UsageObserver?

    init() {
        refreshDevices()
        selectedOutputID = preferredVirtualDevice()?.id
        installUsageObserver()
    }

    deinit {
        if let o = usageObserver { AudioDevices.removeUsageObserver(o) }
    }

    var selectedOutput: AudioDevices.Device? {
        outputDevices.first { $0.id == selectedOutputID }
    }

    var statusText: String {
        if !isEnabled { return "Off" }
        return isActive ? "Removing noise" : "On · waiting for a call"
    }

    func refreshDevices() {
        outputDevices = AudioDevices.all().filter { $0.hasOutput }
        if selectedOutputID == nil || !outputDevices.contains(where: { $0.id == selectedOutputID }) {
            selectedOutputID = preferredVirtualDevice()?.id
        }
    }

    /// Flip the setting. This never directly touches the mic — it only arms or
    /// disarms; `reconcile()` starts/stops the engine based on actual usage.
    func toggle() {
        isEnabled.toggle()
        reconcile()
    }

    func selectOutput(_ id: AudioDeviceID) {
        selectedOutputID = id
        installUsageObserver()   // watch the newly selected virtual device
        if isActive {            // re-route an in-progress session
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
        guard let dev = selectedOutput else { return }
        usageObserver = AudioDevices.addUsageObserver(dev.id) { [weak self] _ in
            DispatchQueue.main.async { self?.reconcile() }
        }
    }

    /// Start or stop the engine so that:
    ///   engine active  ⟺  (setting enabled)  AND  (an app is using the mic)
    private func reconcile() {
        guard let dev = selectedOutput else { return }
        let inUse = AudioDevices.isInputInUse(dev.id)
        let shouldRun = isEnabled && inUse

        if shouldRun && !isActive {
            do {
                try engine.start(outputDevice: dev)
                isActive = true
            } catch {
                isActive = false
                NSLog("ODE: failed to start engine: \(error.localizedDescription)")
            }
        } else if !shouldRun && isActive {
            engine.stop()
            isActive = false
        }
    }

    private func preferredVirtualDevice() -> AudioDevices.Device? {
        outputDevices.first { $0.name.localizedCaseInsensitiveContains("ode") }
            ?? outputDevices.first { $0.name.localizedCaseInsensitiveContains("blackhole") }
            ?? AudioDevices.defaultOutput()
    }
}
