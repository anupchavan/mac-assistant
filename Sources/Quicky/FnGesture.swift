import Foundation

/// Gestures on the trigger key (Settings › Shortcuts) as a pure state machine (no AppKit). Times are
/// milliseconds on a monotonic clock. The monitor feeds events and calls `tick` at `deadline`.
///
///   hold ≥ 200 ms               → holdBegan … holdEnded on release
///   tap, tap (≤ 400 ms apart)   → handsFree
///   tap while hands-free        → handsFreeStop
///   key + Space, ⇧ + key        → typed (⇧ held at key-down never starts the mic)
///   ⌥ + key                     → newChat
///   three taps within 600 ms    → cancel
///   single tap                  → tap (the model decides: follow-up, stop speaking, or nothing)
///   other key while it is down  → discard (fn+arrows, Hyper+letter etc. never fire)
struct FnGesture {
    enum Output: Equatable {
        case preroll, holdBegan, holdEnded(heldMs: Double), handsFree, handsFreeStop, typed, newChat, tap, cancel, discard
    }
    /// A modifier held with the trigger key.
    enum Extra { case shift, option }

    static let holdMs: Double = 200
    static let doubleTapMs: Double = 400
    static let tripleTapMs: Double = 600
    static let spaceKeyCode: Int = 49

    private enum State: Equatable {
        case idle
        case down(at: Double)                 // first press, not yet a hold
        case holding(since: Double)
        case waitSecond(firstDown: Double, up: Double)
        case secondDown(firstDown: Double)    // will become hands-free
        case handsFree(firstDown: Double)
        case handsFreeDown(firstDown: Double, at: Double)
        case typedHeld                        // key is down but already became .typed/.newChat; its release does nothing
    }

    private var state: State = .idle
    private(set) var deadline: Double?

    var isHandsFree: Bool {
        switch state { case .handsFree, .handsFreeDown: return true; default: return false }
    }

    /// Reset from outside, e.g. when the model ends hands-free listening by silence.
    mutating func reset() { state = .idle; deadline = nil }

    mutating func fnDown(_ t: Double, extra: Extra? = nil) -> [Output] {
        switch state {
        case .idle where extra != nil:
            state = .typedHeld; deadline = nil
            return [extra == .shift ? .typed : .newChat]
        case .idle:
            state = .down(at: t); deadline = t + Self.holdMs
            return [.preroll]
        case let .waitSecond(first, up):
            if t - up <= Self.doubleTapMs {
                state = .secondDown(firstDown: first); deadline = nil
                return [.handsFree]
            }
            state = .down(at: t); deadline = t + Self.holdMs
            return [.tap, .preroll]
        case let .handsFree(first):
            state = .handsFreeDown(firstDown: first, at: t); deadline = nil
            return []
        default:
            return []
        }
    }

    /// ⇧ or ⌥ pressed while the key is down, before it became a hold: typed or a new chat instead of voice.
    mutating func extraDown(_ e: Extra, _ t: Double) -> [Output] {
        guard case .down = state else { return [] }
        state = .typedHeld; deadline = nil
        return [e == .shift ? .typed : .newChat]
    }

    mutating func fnUp(_ t: Double) -> [Output] {
        switch state {
        case .typedHeld:
            state = .idle; deadline = nil
            return []
        case .down:
            state = .waitSecond(firstDown: deadlineStart(), up: t); deadline = t + Self.doubleTapMs
            return []
        case let .holding(since):
            state = .idle; deadline = nil
            return [.holdEnded(heldMs: t - since + Self.holdMs)]
        case let .secondDown(first):
            state = .handsFree(firstDown: first); deadline = nil
            return []
        case let .handsFreeDown(first, _):
            state = .idle; deadline = nil
            if t - first <= Self.tripleTapMs { return [.cancel] }
            return [.handsFreeStop]
        default:
            return []
        }
    }

    mutating func otherKeyDown(_ keyCode: Int, _ t: Double) -> [Output] {
        switch state {
        case .down, .holding:
            state = .idle; deadline = nil
            return keyCode == Self.spaceKeyCode ? [.typed] : [.discard]
        case .waitSecond:
            state = .idle; deadline = nil
            return [.discard]
        default:
            return []
        }
    }

    mutating func tick(_ t: Double) -> [Output] {
        guard let d = deadline, t >= d else { return [] }
        switch state {
        case let .down(at):
            state = .holding(since: at + Self.holdMs); deadline = nil
            return [.holdBegan]
        case .waitSecond:
            state = .idle; deadline = nil
            return [.tap]
        default:
            deadline = nil
            return []
        }
    }

    private func deadlineStart() -> Double {
        if case let .down(at) = state { return at }
        return 0
    }
}
