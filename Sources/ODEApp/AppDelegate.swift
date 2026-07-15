import AppKit
import SwiftUI
import AVFoundation
import Sparkle
import ODEKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let controller = ODEController()
    private var abController: ABTestWindowController?
    private var notesController: MeetingNotesWindowController?
    private var hotKey: HotKey?
    private var capturePolicyObserver: NSObjectProtocol?
    /// Sparkle auto-updates (feed: appcast.xml on the repo's main branch,
    /// updated by the release workflow).
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    /// Exclude (or include) a window from screen sharing per the setting.
    private func applyCapturePolicy(_ window: NSWindow?) {
        window?.sharingType = controller.hideFromCapture ? .none : .readOnly
    }

    private func applyCapturePolicyEverywhere() {
        applyCapturePolicy(popover.contentViewController?.view.window)
        applyCapturePolicy(notesController?.window)
        applyCapturePolicy(abController?.window)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ask for microphone consent up front. If the TCC prompt instead fires
        // mid-call inside a CoreAudio property call, it blocks that call — and
        // with it whatever thread the engine was started from.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted { NSLog("ODE: microphone access denied") }
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            updateIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }

        let panel = PanelView(
            controller: controller,
            onTest: { [weak self] in self?.openABTest() },
            onNotes: { [weak self] showLive in self?.openNotes(showLive: showLive) },
            onCheckUpdates: { [weak self] in
                self?.popover.performClose(nil)
                self?.updater.checkForUpdates(nil)
            },
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

        // ⌃⌥⌘O: toggle noise cancellation from anywhere.
        hotKey = HotKey { [weak self] in self?.controller.toggleMaster() }

        // Re-apply the screen-capture policy when the setting flips.
        capturePolicyObserver = NotificationCenter.default.addObserver(
            forName: .odeCapturePolicyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyCapturePolicyEverywhere()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting mid-call used to drop the in-progress meeting transcript:
        // engines stopped but the save step never ran. Delay termination until
        // the transcript is flushed and saved (bounded so quit can't hang).
        guard controller.transcribing else { return .terminateNow }
        var replied = false
        let reply = {
            DispatchQueue.main.async {
                guard !replied else { return }
                replied = true
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        controller.stopIfRunning()
        controller.finishTranscription(completion: reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: reply)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop processing and hide the virtual devices so users never see a
        // dead "ODE Microphone"/"ODE Speaker" while the app isn't running.
        controller.stopIfRunning()
        controller.hideVirtualDevices()
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
            applyCapturePolicy(popover.contentViewController?.view.window)
        }
    }

    private var iconActive: Bool?

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let denoising = (controller.micActive && controller.micEnabled)
            || (controller.speakerActive && controller.speakerEnabled)
        guard denoising != iconActive else { return }  // redraw only on change
        iconActive = denoising
        button.image = StatusIcon.image(active: denoising)
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
        applyCapturePolicy(abController?.window)
    }

    private func openNotes(showLive: Bool = false) {
        popover.performClose(nil)
        controller.markMeetingsOpened()
        // Recreate so the list reflects newly saved transcripts. The controller
        // reference powers the live-meeting view (transcript-so-far + Q&A).
        notesController = MeetingNotesWindowController(controller: controller,
                                                       showLive: showLive)
        NSApp.activate(ignoringOtherApps: true)
        notesController?.showWindow(nil)
        notesController?.window?.makeKeyAndOrderFront(nil)
        applyCapturePolicy(notesController?.window)
    }

    private func quit() {
        controller.stopIfRunning()
        NSApp.terminate(nil)
    }
}
