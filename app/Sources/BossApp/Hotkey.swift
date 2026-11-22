import AppKit
import CoreGraphics
import QuartzCore
import BossCore

/// Listen-only CGEventTap for Right Option (keycode 61) and Esc (53), feeding GestureDetector.
@MainActor
final class Hotkey {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = GestureDetector()
    private var ticker: Timer?
    var onGesture: (([GestureEvent]) -> Void)?
    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    static let rightOptionKeycode: Int64 = 61
    static let escKeycode: Int64 = 53
    static let rightAltMask: UInt64 = 0x40   // NX_DEVICERALTKEYMASK

    /// Try to install the tap. Returns false without Input Monitoring permission.
    @discardableResult
    func install(requestIfNeeded: Bool) -> Bool {
        if tap != nil { return isActive }
        if !CGPreflightListenEventAccess() && requestIfNeeded { _ = CGRequestListenEventAccess() }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(mask), callback: hotkeyCallback, userInfo: refcon) else {
            return false
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    fileprivate func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }; detector.reset() }

    fileprivate func handle(type: CGEventType, keycode: Int64, flags: UInt64) {
        let now = CACurrentMediaTime()
        var input: KeyInput?
        switch type {
        case .flagsChanged where keycode == Self.rightOptionKeycode:
            input = (flags & Self.rightAltMask) != 0 ? .optionDown : .optionUp
        case .keyDown:
            input = keycode == Self.escKeycode ? .escape : .otherKey
        default: break
        }
        guard let input else { return }
        let events = detector.handle(input, at: now)
        if !events.isEmpty { onGesture?(events) }
        if case .pressed = detector.state { startTicker() } else { stopTicker() }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let e = self.detector.tick(at: CACurrentMediaTime())
                if !e.isEmpty { self.onGesture?(e) }
                if case .pressed = self.detector.state {} else { self.stopTicker() }
            }
        }
        RunLoop.main.add(ticker!, forMode: .common)
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }
}

private func hotkeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let hk = Unmanaged<Hotkey>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { hk.reenable() }
        return Unmanaged.passUnretained(event)
    }
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.rawValue
    MainActor.assumeIsolated { hk.handle(type: type, keycode: keycode, flags: flags) }
    return Unmanaged.passUnretained(event)
}
