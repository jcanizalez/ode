import AppKit
import ODEKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = LiveEngine()
    private var running = false
    private var selectedOutput: AudioDevices.Device?
    private var abController: ABTestWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        selectedOutput = preferredVirtualDevice()
        updateIcon()
        rebuildMenu()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: running ? "Denoise: On" : "Denoise: Off",
                                action: #selector(toggleDenoise), keyEquivalent: "")
        toggle.target = self
        toggle.state = running ? .on : .off
        menu.addItem(toggle)

        // Output device submenu
        let outItem = NSMenuItem(title: "Output Device", action: nil, keyEquivalent: "")
        let outMenu = NSMenu()
        for dev in AudioDevices.all() where dev.hasOutput {
            let mi = NSMenuItem(title: dev.name, action: #selector(selectOutput(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = dev.name
            mi.state = (dev.id == selectedOutput?.id) ? .on : .off
            outMenu.addItem(mi)
        }
        outItem.submenu = outMenu
        menu.addItem(outItem)

        if let sel = selectedOutput {
            let info = NSMenuItem(title: "→ \(sel.name)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }

        menu.addItem(.separator())

        let test = NSMenuItem(title: "Test (Before / After)…",
                              action: #selector(openABTest), keyEquivalent: "t")
        test.target = self
        menu.addItem(test)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ODE", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol = running ? "waveform.circle.fill" : "waveform.circle"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "ODE") {
            img.isTemplate = true
            button.image = img
        } else {
            button.title = running ? "ODE•" : "ODE"
        }
    }

    private func preferredVirtualDevice() -> AudioDevices.Device? {
        let outs = AudioDevices.all().filter { $0.hasOutput }
        return outs.first { $0.name.localizedCaseInsensitiveContains("ode") }
            ?? outs.first { $0.name.localizedCaseInsensitiveContains("blackhole") }
            ?? AudioDevices.defaultOutput()
    }

    // MARK: - Actions

    @objc private func toggleDenoise() {
        if running {
            engine.stop()
            running = false
        } else {
            do {
                try engine.start(outputDevice: selectedOutput)
                running = true
            } catch {
                alert("Could not start denoising", error.localizedDescription)
            }
        }
        updateIcon()
        rebuildMenu()
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let dev = AudioDevices.find(name: name) else { return }
        selectedOutput = dev
        if running {           // re-route live: restart engine on new device
            engine.stop()
            try? engine.start(outputDevice: selectedOutput)
        }
        rebuildMenu()
    }

    @objc private func openABTest() {
        if abController == nil {
            abController = ABTestWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        abController?.showWindow(nil)
        abController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        if running { engine.stop() }
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.runModal()
    }
}
