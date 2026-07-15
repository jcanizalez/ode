import AppKit

/// Menu-bar rendition of the app icon's "Clearing Wave": noise bars resolving
/// into voice bars. Drawn as a TEMPLATE image — the only kind macOS
/// guarantees to stay visible against every menu-bar tint and wallpaper
/// (0.9.x shipped this as a non-template color drawing, which rendered
/// invisible on some setups and looked like the app wasn't running).
/// Alpha carries the noise-vs-voice contrast; the denoising state is shown
/// by tinting the status button (contentTintColor), not by baked-in color.
enum StatusIcon {
    static func image(active: Bool) -> NSImage {
        let size = NSSize(width: 24, height: 17)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let midY = rect.midY

            func bar(x: CGFloat, height: CGFloat, width: CGFloat,
                     yJitter: CGFloat, alpha: CGFloat) {
                let r = CGRect(x: x - width/2, y: midY - height/2 + yJitter,
                               width: width, height: height)
                ctx.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: width/2,
                                   cornerHeight: width/2, transform: nil))
                ctx.fillPath()
            }

            // Noise (left): thin, jittered, faint.
            bar(x: 2.5, height: 4, width: 1.8, yJitter: 1, alpha: 0.4)
            bar(x: 5.5, height: 7, width: 1.8, yJitter: -1, alpha: 0.4)
            bar(x: 8.5, height: 5, width: 1.8, yJitter: 1, alpha: 0.4)
            // Voice (right): bold, symmetric, solid.
            bar(x: 12, height: 9, width: 2.6, yJitter: 0, alpha: 1)
            bar(x: 16, height: 14, width: 2.6, yJitter: 0, alpha: 1)
            bar(x: 20, height: 9, width: 2.6, yJitter: 0, alpha: 1)
            return true
        }
        image.isTemplate = true
        return image
    }
}
