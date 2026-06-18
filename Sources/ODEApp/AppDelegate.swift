import AppKit
import SwiftUI
import ODEKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let controller = ODEController()
    private var abController: ABTestWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            updateIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }

        let panel = PanelView(
            controller: controller,
            onTest: { [weak self] in self?.openABTest() },
            onQuit: { [weak self] in self?.quit() }
        )
        let hosting = NSHostingController(rootView: panel)
        // Let the SwiftUI content drive the popover size so there is no empty
        // padding below the panel.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .vibrantDark)

        // Keep the menu-bar icon in sync with the running state.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            controller.refreshDevices()
            guard let button = statusItem.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let denoising = (controller.micActive && controller.micEnabled)
            || (controller.speakerActive && controller.speakerEnabled)
        let symbol = denoising ? "waveform.circle.fill" : "waveform.circle"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "ODE") {
            img.isTemplate = true
            button.image = img
        } else {
            button.title = denoising ? "ODE•" : "ODE"
        }
    }

    // MARK: - Actions

    private func openABTest() {
        popover.performClose(nil)
        if abController == nil {
            abController = ABTestWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        abController?.showWindow(nil)
        abController?.window?.makeKeyAndOrderFront(nil)
    }

    private func quit() {
        controller.stopIfRunning()
        NSApp.terminate(nil)
    }
}
