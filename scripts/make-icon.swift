// ODE app icon — "The Clearing Wave": scratchy gray noise on the left
// resolves into bold, glowing voice bars on the right. Rendered
// programmatically so the icon is versioned and tweakable like code.
//
// Usage: swift scripts/make-icon.swift <output.iconset-dir>
// (build-app.sh compiles the iconset into ODE.icns via iconutil)

import AppKit
import CoreGraphics

let master: CGFloat = 1024
let accent = CGColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1)
let accentGlow = CGColor(red: 0.30, green: 0.56, blue: 1.0, alpha: 0.55)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func render(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / master, y: CGFloat(size) / master)

    // --- Background: dark glass squircle ---
    let rect = CGRect(x: 0, y: 0, width: master, height: master)
    let path = CGPath(roundedRect: rect.insetBy(dx: 6, dy: 6),
                      cornerWidth: 230, cornerHeight: 230, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(colorsSpace: srgb, colors: [
        CGColor(red: 0.13, green: 0.14, blue: 0.19, alpha: 1),
        CGColor(red: 0.05, green: 0.055, blue: 0.08, alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: master/2, y: master),
                           end: CGPoint(x: master/2, y: 0), options: [])
    let hl = CGGradient(colorsSpace: srgb, colors: [
        CGColor(gray: 1, alpha: 0.07), CGColor(gray: 1, alpha: 0)] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(hl, startCenter: CGPoint(x: master/2, y: master*0.92),
                           startRadius: 0,
                           endCenter: CGPoint(x: master/2, y: master*0.92),
                           endRadius: master*0.8, options: [])
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
    ctx.setLineWidth(6)
    ctx.addPath(path)
    ctx.strokePath()

    // --- Bars ---
    func bar(x: CGFloat, midY: CGFloat, height: CGFloat, width: CGFloat,
             color: CGColor, glow: Bool) {
        let r = CGRect(x: x - width/2, y: midY - height/2, width: width, height: height)
        let p = CGPath(roundedRect: r, cornerWidth: width/2, cornerHeight: width/2,
                       transform: nil)
        if glow {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 46, color: accentGlow)
            ctx.setFillColor(color)
            ctx.addPath(p); ctx.fillPath()
            ctx.restoreGState()
        } else {
            ctx.setFillColor(color)
            ctx.addPath(p); ctx.fillPath()
        }
    }

    let midY = master/2
    // Noise: thin, irregular, jittered, gray.
    for (x, h, j): (CGFloat, CGFloat, CGFloat) in [
        (170, 96, 22), (232, 170, -26), (294, 76, 14), (356, 200, -12), (418, 120, 26),
    ] {
        bar(x: x, midY: midY + j, height: h, width: 30,
            color: CGColor(gray: 0.62, alpha: 0.42), glow: false)
    }
    // Transition.
    bar(x: 486, midY: midY, height: 260, width: 44,
        color: CGColor(red: 0.30, green: 0.50, blue: 0.85, alpha: 0.75), glow: false)
    // Voice: bold, symmetric, glowing.
    for (x, h): (CGFloat, CGFloat) in [(566, 380), (654, 560), (742, 380), (826, 220)] {
        bar(x: x, midY: midY, height: h, width: 58, color: accent, glow: true)
    }

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift make-icon.swift <output.iconset>\n", stderr)
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Full macOS iconset.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    let name = scale == 1 ? "icon_\(points)x\(points).png"
                          : "icon_\(points)x\(points)@2x.png"
    writePNG(render(size: px), to: outDir.appendingPathComponent(name))
}
print("iconset written to \(outDir.path)")
