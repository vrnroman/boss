import Foundation

/// Raw key input fed to the gesture detector (already decoded from CGEvents).
public enum KeyInput: Equatable, Sendable {
    case optionDown      // Right Option pressed
    case optionUp        // Right Option released
    case escape          // Esc key down
    case otherKey        // any other key down (Option used as a chord modifier)
}

/// What the detector decided.
public enum GestureEvent: Equatable, Sendable {
    /// Right Option went down: start buffering (pre-roll is kept), nothing is committed yet.
    case armed
    /// The press has lasted the hold threshold: this is push-to-talk, recording is live.
    case talkStart
    /// Released after a hold: send the recording.
    case talkEnd
    /// Released before the hold threshold (a tap); any armed buffer is discarded.
    case tap
    /// Second tap within the double-tap window (reserved for M3 hands-free).
    case doubleTap
    /// Esc while armed or recording, or Option used as a chord: discard, send nothing.
    case cancel
}

/// Pure state machine for the Right Option gestures.
///
/// Timing rules (all in seconds, timestamps are monotonic):
/// - a press lasting `>= holdThreshold` (300 ms) is a hold → push-to-talk;
///   `tick(at:)` emits `.talkStart` the moment the threshold is crossed,
///   and a release that arrives first (missed tick) emits `.talkStart, .talkEnd` together.
/// - a release before the threshold is a tap;
/// - two taps whose releases are `<= doubleTapWindow` (350 ms) apart are a double tap.
/// - Esc while armed/recording cancels; the following release emits nothing.
public struct GestureDetector: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case pressed(since: TimeInterval)
        case recording(since: TimeInterval)
        case cancelled  // waiting for the Option release, ignoring it
    }

    public let holdThreshold: TimeInterval
    public let doubleTapWindow: TimeInterval
    public private(set) var state: State = .idle
    private var lastTapAt: TimeInterval?

    public init(holdThreshold: TimeInterval = 0.300, doubleTapWindow: TimeInterval = 0.350) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    public var isRecording: Bool { if case .recording = state { return true }; return false }

    /// Feed one key input observed at time `t`.
    public mutating func handle(_ input: KeyInput, at t: TimeInterval) -> [GestureEvent] {
        switch (state, input) {
        case (.idle, .optionDown):
            state = .pressed(since: t)
            return [.armed]
        case (.pressed(let since), .optionUp):
            if t - since >= holdThreshold - 1e-9 {
                state = .idle
                lastTapAt = nil
                return [.talkStart, .talkEnd]
            }
            state = .idle
            if let last = lastTapAt, t - last <= doubleTapWindow + 1e-9 {
                lastTapAt = nil
                return [.doubleTap]
            }
            lastTapAt = t
            return [.tap]
        case (.recording, .optionUp):
            state = .idle
            lastTapAt = nil
            return [.talkEnd]
        case (.pressed, .escape), (.recording, .escape):
            state = .cancelled
            lastTapAt = nil
            return [.cancel]
        case (.pressed, .otherKey):
            // Right Option used as a modifier for typing (e.g. ⌥E): not a gesture.
            state = .cancelled
            lastTapAt = nil
            return [.cancel]
        case (.cancelled, .optionUp):
            state = .idle
            return []
        case (.pressed, .optionDown), (.recording, .optionDown), (.cancelled, .optionDown):
            return [] // auto-repeat / duplicate flagsChanged
        default:
            return []
        }
    }

    /// Advance time; emits `.talkStart` when a press crosses the hold threshold.
    public mutating func tick(at t: TimeInterval) -> [GestureEvent] {
        if case .pressed(let since) = state, t - since >= holdThreshold - 1e-9 {
            state = .recording(since: since)
            lastTapAt = nil
            return [.talkStart]
        }
        return []
    }

    /// Forget any pending press (e.g. the event tap was disabled).
    public mutating func reset() { state = .idle; lastTapAt = nil }
}
