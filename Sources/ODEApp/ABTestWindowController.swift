import AppKit
import SwiftUI

/// Hosts the SwiftUI `ABTestView` in a small floating window.
final class ABTestWindowController: NSWindowController {
    private let model = ABTestModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "The ODE magic"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ABTestView(model: model))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func close() {
        model.cleanup()
        super.close()
    }
}
