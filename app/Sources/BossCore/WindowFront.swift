import CoreGraphics

/// One on-screen window, as the window server lists them (front to back).
public struct ScreenWindow: Equatable, Sendable {
    public var pid: Int32
    public var number: Int
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double
    public init(pid: Int32, number: Int, layer: Int, bounds: CGRect, alpha: Double = 1) {
        self.pid = pid; self.number = number; self.layer = layer; self.bounds = bounds; self.alpha = alpha
    }
}

/// What a click on the menu-bar ring does (Roman, 2026-11-26: "clicking the Boss icon near the
/// clock, I still cannot see the window"). macOS 26 refuses to activate an accessory app from a
/// status-item click, so "is Boss the active app" said no forever and the ring only ever tried to
/// show a window it could not raise. The answer now comes from what is on screen.
public enum WindowFront {
    /// Boss counts as "in front" when one of its windows is on screen and no other app's normal
    /// window covers any part of it. The menu bar, Dock and system overlays (other layers) don't count.
    public static func isUnobscured(ours: Set<Int>, pid: Int32, list: [ScreenWindow]) -> Bool {
        guard list.contains(where: { ours.contains($0.number) }) else { return false }
        // Any of ours (panel or chat) partly under another app's window: not in front.
        for (i, w) in list.enumerated() where ours.contains(w.number) {
            for o in list[..<i] where o.layer == 0 && o.pid != pid && o.alpha > 0.05 && o.bounds.intersects(w.bounds) {
                return false
            }
        }
        return true
    }

    public enum RingAction: Equatable, Sendable { case show, hide }

    /// Hidden, or covered by another app: bring it forward. Fully visible: hide it.
    public static func ringAction(panelVisible: Bool, unobscured: Bool) -> RingAction {
        panelVisible && unobscured ? .hide : .show
    }
}
