import AppKit

/// Menu-bar rendition of the app icon's "Clearing Wave": noise bars resolving
/// into voice bars. Drawn at runtime so it adapts to menu-bar appearance —
/// blue + bold while denoising, dimmed monochrome while idle.
enum StatusIcon {
    static func image(active: Bool) -> NSImage {
        let size = NSSize(width: 24, height: 17)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let midY = rect.midY

            func bar(x: CGFloat, height: CGFloat, width: CGFloat,
                     yJitter: CGFloat, color: NSColor) {
                let r = CGRect(x: x - width/2, y: midY - height/2 + yJitter,
                               width: width, height: height)
                ctx.setFillColor(color.cgColor)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: width/2,
                                   cornerHeight: width/2, transform: nil))
                ctx.fillPath()
            }

            // Semantic colors so the idle icon adapts to menu-bar appearance
            // (this drawing block re-runs per appearance).
            let noise = NSColor.labelColor.withAlphaComponent(0.35)
            let voice = active ? NSColor.controlAccentColor
                               : NSColor.labelColor.withAlphaComponent(0.75)

            // Noise (left): thin, jittered.
            bar(x: 2.5, height: 4, width: 1.8, yJitter: 1, color: noise)
            bar(x: 5.5, height: 7, width: 1.8, yJitter: -1, color: noise)
            bar(x: 8.5, height: 5, width: 1.8, yJitter: 1, color: noise)
            // Voice (right): bold, symmetric.
            bar(x: 12, height: 9, width: 2.6, yJitter: 0, color: voice)
            bar(x: 16, height: 14, width: 2.6, yJitter: 0, color: voice)
            bar(x: 20, height: 9, width: 2.6, yJitter: 0, color: voice)
            return true
        }
        // Not a template: the accent-blue "active" state is the point.
        image.isTemplate = false
        return image
    }
}
