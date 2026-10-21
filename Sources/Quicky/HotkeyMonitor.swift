import AppKit
import CoreGraphics

/// Global CGEventTap for fn gestures, plus Esc and the computer-use stop signals.
/// Active tap (can swallow fn+Space and Esc) when Accessibility is granted, else listen-only.
final class HotkeyMonitor {
    static let fnKeyCode: Int64 = 63          // kVK_Function (also the Globe key)
    static let rightOptionKeyCode: Int64 = 61 // fallback modifier
    static let escKeyCode: Int64 = 53
    static let shiftKeyCodes: Set<Int64> = [56, 60]
    static let controlKeyCodes: Set<Int64> = [59, 62]

    var useRightOption = UserDefaults.standard.bool(forKey: "useRightOption")
    var onGesture: ((FnGesture.Output) -> Void)?
    /// Return true to swallow the Esc key (panel is showing something Esc should stop).
    var onEscape: (() -> Bool)?
    /// Mouse moved by the user (computer use stops when the user grabs the mouse).
    /// Real (not our synthetic) mouse movement deltas in points, and `clicked` for a real click.
    var onUserMouse: ((_ dx: Double, _ dy: Double, _ clicked: Bool) -> Void)?

    /// Every event we post carries this in eventSourceUserData. Posted events reach our tap later,
    /// after `syntheticDepth` is back to 0, so the tag is what tells them apart from the user.
    static let syntheticTag: Int64 = 0x4153_5354
    static func syntheticSource(_ state: CGEventSourceStateID) -> CGEventSource? {
        let s = CGEventSource(stateID: state)
        s?.userData = syntheticTag
        return s
    }

    private var machine = FnGesture()
    private var control = ControlDoubleTap()
    private var controlIsDown = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: DispatchWorkItem?
    private var keyIsDown = false
    private var swallowNextSpaceUp = false
    /// Set while our own executor posts synthetic events, so they don't count as the user.
    var syntheticDepth = 0

    var isHandsFree: Bool { machine.isHandsFree }
    /// The tap sees every Esc first, so the panel's own key handler must not act on it again.
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    func resetGesture() { machine.reset(); timer?.cancel() }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        for option in [CGEventTapOptions.defaultTap, .listenOnly] {
            if let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: option,
                                         eventsOfInterest: mask, callback: callback, userInfo: refcon) {
                tap = t
                source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: t, enable: true)
                Log.info("event tap started (\(option == .defaultTap ? "active" : "listen-only"))")
                return true
            }
        }
        Log.error("event tap failed: grant Input Monitoring and Accessibility")
        return false
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil; source = nil
        keyIsDown = false
        machine.reset(); timer?.cancel()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if Self.controlKeyCodes.contains(code) {
                let down = flags.contains(.maskControl)
                guard down != controlIsDown else { return Unmanaged.passUnretained(event) }
                controlIsDown = down
                let others: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn]
                if !flags.intersection(others).isEmpty { control.spoil() }
                if down { control.down(Self.now()) }
                else if control.up(Self.now()) { Log.info("control double-tap"); emit([.controlDoubleTap]) }
                return Unmanaged.passUnretained(event)
            }
            // Any other modifier change spoils a Control double-tap in progress.
            control.spoil()
            if keyIsDown, Self.shiftKeyCodes.contains(code), flags.contains(.maskShift) {
                emit(machine.shiftDown(Self.now()))
                return Unmanaged.passUnretained(event)
            }
            let watched = useRightOption ? Self.rightOptionKeyCode : Self.fnKeyCode
            guard code == watched else { return Unmanaged.passUnretained(event) }
            let down = useRightOption ? flags.contains(.maskAlternate) : flags.contains(.maskSecondaryFn)
            if down != keyIsDown {
                keyIsDown = down
                let t = Self.now()
                let shift = flags.contains(.maskShift)
                let out = down ? machine.fnDown(t, shift: shift) : machine.fnUp(t)
                Log.info("fn \(down ? "down" : "up")\(shift ? " +shift" : "") → \(out.map { "\($0)" }.joined(separator: ", "))")
                emit(out)
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            control.spoil()
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Self.escKeyCode, syntheticDepth == 0, !isSynthetic(event) {
                if onEscape?() == true { return nil }
                return Unmanaged.passUnretained(event)
            }
            if keyIsDown {
                let out = machine.otherKeyDown(Int(code), Self.now())
                emit(out)
                if out.contains(.typed) { swallowNextSpaceUp = true; return nil }
            }
            return Unmanaged.passUnretained(event)
        case .keyUp:
            if swallowNextSpaceUp, event.getIntegerValueField(.keyboardEventKeycode) == Int64(FnGesture.spaceKeyCode) {
                swallowNextSpaceUp = false
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .mouseMoved, .leftMouseDown:
            if syntheticDepth == 0, !isSynthetic(event) {
                onUserMouse?(event.getDoubleValueField(.mouseEventDeltaX), event.getDoubleValueField(.mouseEventDeltaY), type == .leftMouseDown)
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func isSynthetic(_ e: CGEvent) -> Bool { e.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag }

    private func emit(_ outputs: [FnGesture.Output]) {
        for o in outputs { if o != .preroll { Log.info("gesture \(o)") }; onGesture?(o) }
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        guard let d = machine.deadline else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.emit(self.machine.tick(Self.now()))
        }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, Int(d - Self.now())) + 1), execute: item)
    }
}
