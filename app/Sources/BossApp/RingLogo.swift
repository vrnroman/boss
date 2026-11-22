import AppKit

/// The Boss mark: one ring with five sessions set into the band ("One voice to rule them all").
/// The centre stone carries the state colour. Drawn at runtime so the band follows the menu bar's
/// light or dark appearance.
enum RingLogo {
    static func draw(in r: NSRect, band: NSColor, stone: NSColor, cutout: NSColor) {
        let w = min(r.width, r.height)
        let x = r.midX - w / 2, y = r.midY - w / 2
        band.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: x + w * 0.14, y: y + w * 0.14, width: w * 0.72, height: w * 0.72))
        ring.lineWidth = w * 0.13
        ring.stroke()
        for a in stride(from: 0.0, to: 360.0, by: 72.0) {
            let t = (a + 90) * .pi / 180
            let cx = x + w * 0.5 + cos(t) * w * 0.36, cy = y + w * 0.5 + sin(t) * w * 0.36
            let hole = NSBezierPath(ovalIn: NSRect(x: cx - w * 0.06, y: cy - w * 0.06, width: w * 0.12, height: w * 0.12))
            if cutout == .clear {
                // Punch through, so the menu bar shows around each session stone.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .clear
                hole.fill()
                NSGraphicsContext.restoreGraphicsState()
            } else {
                cutout.setFill(); hole.fill()
            }
            band.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - w * 0.035, y: cy - w * 0.035, width: w * 0.07, height: w * 0.07)).fill()
        }
        stone.setFill()
        NSBezierPath(ovalIn: NSRect(x: x + w * 0.39, y: y + w * 0.39, width: w * 0.22, height: w * 0.22)).fill()
    }

    /// Menu-bar image (18 pt). The band uses the menu bar's text colour; the stone shows state.
    static func menuBarImage(stone: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            // The cut-outs around the session stones are punched through (clear) so any menu bar shows through.
            draw(in: r.insetBy(dx: 0.5, dy: 0.5), band: .labelColor, stone: stone, cutout: .clear)
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "Boss"
        return img
    }
}
