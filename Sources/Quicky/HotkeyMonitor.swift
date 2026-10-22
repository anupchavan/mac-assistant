import AppKit
import CoreGraphics

/// Global CGEventTap for the trigger key's gestures (Settings › Shortcuts), plus Esc and the
/// computer-use stop signals. Active tap (can swallow key + Space, Esc, and our Caps Lock Hyperkey)
/// when Accessibility is granted, else listen-only.
final class HotkeyMonitor {
    static let escKeyCode: Int64 = 53
    static let shiftKeyCodes: Set<Int64> = [56, 60]
    static let optionKeyCodes: Set<Int64> = [58, 61]

    var trigger = TriggerKey.chosen
    var capsLockHyper = CapsLockHyper.enabled
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
    private var hyper = HyperDetector()
    private var capsIsDown = false
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
        keyIsDown = false; capsIsDown = false
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
            if trigger == .hyper {
                if capsIsDown { return Unmanaged.passUnretained(event) }
                switch hyper.flags(flags, at: Self.now()) {
                case let .down(extra)?: triggerChanged(down: true, extra: extra)
                case .up?: triggerChanged(down: false, extra: nil)
                case nil: break
                }
                return Unmanaged.passUnretained(event)
            }
            if trigger.keyCodes.contains(code) {
                let down = trigger.isDown(flags)
                guard down != keyIsDown else { return Unmanaged.passUnretained(event) }
                if down {
                    // Only ⇧ or ⌥ may be held with it; ⌘⌃ etc. mean it is part of someone else's shortcut.
                    let held = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).subtracting(trigger.ownFlags)
                    guard held.isSubset(of: [.maskShift, .maskAlternate]) else { return Unmanaged.passUnretained(event) }
                    triggerChanged(down: true, extra: held.contains(.maskShift) ? .shift : held.contains(.maskAlternate) ? .option : nil)
                } else {
                    triggerChanged(down: false, extra: nil)
                }
                return Unmanaged.passUnretained(event)
            }
            if keyIsDown, Self.shiftKeyCodes.contains(code), flags.contains(.maskShift) {
                emit(machine.extraDown(.shift, Self.now()))
            } else if keyIsDown, Self.optionKeyCodes.contains(code), flags.contains(.maskAlternate) {
                emit(machine.extraDown(.option, Self.now()))
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if trigger == .hyper, capsLockHyper, code == CapsLockHyper.f18KeyCode {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, !capsIsDown {
                    capsIsDown = true
                    let held = event.flags
                    triggerChanged(down: true, extra: held.contains(.maskShift) ? .shift : held.contains(.maskAlternate) ? .option : nil)
                }
                return nil
            }
            if capsIsDown { event.flags.formUnion(HyperDetector.all) }   // Caps Lock + key is Hyper + key
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
            if capsIsDown, event.getIntegerValueField(.keyboardEventKeycode) == CapsLockHyper.f18KeyCode {
                capsIsDown = false
                triggerChanged(down: false, extra: nil)
                return nil
            }
            if capsIsDown { event.flags.formUnion(HyperDetector.all) }
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

    private func triggerChanged(down: Bool, extra: FnGesture.Extra?) {
        guard down != keyIsDown else { return }
        keyIsDown = down
        let t = Self.now()
        let out = down ? machine.fnDown(t, extra: extra) : machine.fnUp(t)
        Log.info("\(trigger.label) \(down ? "down" : "up")\(extra.map { " +\($0)" } ?? "") → \(out.map { "\($0)" }.joined(separator: ", "))")
        emit(out)
    }

    /// Settings changed the trigger key or the Caps Lock Hyperkey.
    func reloadTrigger() {
        trigger = TriggerKey.chosen
        capsLockHyper = CapsLockHyper.enabled
        CapsLockHyper.apply(trigger == .hyper && capsLockHyper)
        keyIsDown = false; capsIsDown = false; hyper = HyperDetector()
        machine.reset(); timer?.cancel()
        Log.info("trigger \(trigger.label)\(trigger == .hyper ? (capsLockHyper ? " (Caps Lock)" : " (external)") : "")")
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
