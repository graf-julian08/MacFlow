// Renders MacFlow's app icon (the radial wheel on a soft squircle) into an
// .iconset and converts it with iconutil. Usage: swift Scripts/make-icon.swift <out.icns>
import AppKit
import CoreGraphics

func render(_ size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    // macOS icon grid: 824 pt body, centred, continuous corners.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(squircle); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3), colors: [
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [0.97, 0.98, 1.0, 1])!, CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [0.86, 0.89, 0.95, 1])!] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Wheel
    let center = CGPoint(x: 512, y: 512)
    let outer: CGFloat = 300, inner: CGFloat = 138, count = 7
    let gap = 0.07
    for i in 0..<count {
        let slice = 2 * Double.pi / Double(count)
        let mid = Double(i) * slice + .pi / 2
        let a0 = mid - slice / 2 + gap / 2, a1 = mid + slice / 2 - gap / 2
        let path = CGMutablePath()
        path.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()
        let highlighted = i == 0
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: CGColor(gray: 0, alpha: highlighted ? 0.25 : 0.12))
        ctx.addPath(path)
        ctx.setFillColor(highlighted ? CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [0.0, 0.47, 1.0, 1])! : CGColor(gray: 1, alpha: 0.95))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: highlighted ? 0 : 0.07)); ctx.setLineWidth(3); ctx.strokePath()
    }
    // Centre disc with a convert glyph
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: CGColor(gray: 0, alpha: 0.15))
    ctx.addEllipse(in: CGRect(x: center.x - 96, y: center.y - 96, width: 192, height: 192))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 96, weight: .semibold)) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor(displayP3Red: 0.0, green: 0.47, blue: 1.0, alpha: 1).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let w = symbol.size.width, h = symbol.size.height
        tinted.draw(in: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: render(px))
        try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print(p.terminationStatus == 0 ? "Icon written to \(out.path)" : "iconutil failed")
