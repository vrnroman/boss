import Foundation

/// One rule for every talk control (panel button, ⌥Space): hold it and release to send
/// (push-to-talk), or tap it once to start and tap again to send (toggle).
public struct TalkPress: Sendable {
    public enum Action: Equatable, Sendable { case start, stop, none }
    public static let holdThreshold: Double = 0.3
    public private(set) var recording = false
    public private(set) var latched = false
    private var pressedAt: Double?

    public init() {}

    public mutating func press(at t: Double) -> Action {
        if recording && latched {          // second tap of a toggle: send
            recording = false; latched = false; pressedAt = nil
            return .stop
        }
        guard !recording else { return .none }
        recording = true; latched = false; pressedAt = t
        return .start
    }

    public mutating func release(at t: Double) -> Action {
        guard recording, let p = pressedAt else { return .none }
        pressedAt = nil
        if t - p >= Self.holdThreshold {   // it was a hold: send on release
            recording = false
            return .stop
        }
        latched = true                     // a quick tap: keep recording until the next tap
        return .none
    }

    /// Recording ended elsewhere (Esc, the engine, the answer window).
    public mutating func reset() { recording = false; latched = false; pressedAt = nil }
}
