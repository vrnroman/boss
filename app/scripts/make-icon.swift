// Draws the Boss app icon (one ring, five sessions, gold on a dark tile) into an .iconset folder.
// Usage: swift make-icon.swift <out.iconset>
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let gold = NSColor(red: 0.96, green: 0.80, blue: 0.36, alpha: 1)
let tile = NSColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), r = NSRect(x: 0, y: 0, width: s, height: s)
    let inset = r.insetBy(dx: s * 0.09, dy: s * 0.09)
    tile.setFill(); NSBezierPath(roundedRect: inset, xRadius: s * 0.19, yRadius: s * 0.19).fill()
    let w = inset.width * 0.74, x = inset.midX - w / 2, y = inset.midY - w / 2
    gold.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: x + w * 0.14, y: y + w * 0.14, width: w * 0.72, height: w * 0.72)); ring.lineWidth = w * 0.13; ring.stroke()
    for a in stride(from: 0.0, to: 360.0, by: 72.0) {
        let t = (a + 90) * .pi / 180, cx = x + w * 0.5 + cos(t) * w * 0.36, cy = y + w * 0.5 + sin(t) * w * 0.36
        tile.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - w * 0.06, y: cy - w * 0.06, width: w * 0.12, height: w * 0.12)).fill()
        gold.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - w * 0.035, y: cy - w * 0.035, width: w * 0.07, height: w * 0.07)).fill()
    }
    gold.setFill(); NSBezierPath(ovalIn: NSRect(x: x + w * 0.39, y: y + w * 0.39, width: w * 0.22, height: w * 0.22)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (base, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = sc == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * sc).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
