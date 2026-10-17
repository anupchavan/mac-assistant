import AppKit
import CoreGraphics
import QuickyCore

/// The `CGEventTap`. It keeps one raw bit (`fnHeld`) so ordinary typing never crosses into the core;
/// what a press means is the core's call, and its `Disposition` decides whether the key is swallowed.
@MainActor
final class Hotkey {
    /// Every event Quicky posts carries this in its source's userData. Posted events reach the tap
    /// later, after any synthetic depth is back to 0, so the tag is the only reliable mark.
    static let syntheticTag: Int64 = 0x5155_4943_4B59

    private static let escapeKeyCode: Int64 = 53
    private static let fnKeyCode: Int64 = 63
    private static let shiftKeyCodes: Set<Int64> = [56, 60]

    private let engine: Engine
    private let panel: PanelWindow
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fnHeld = false
    /// A swallowed keyDown's keyUp is swallowed too, so the front app never sees half a keystroke.
    private var swallowedKeyUps: Set<Int64> = []

    init(engine: Engine, panel: PanelWindow) {
        self.engine = engine
        self.panel = panel
    }

    /// (Re)creates the tap. A tap made before a permission grant can stay listen-only or get no fn
    /// events, so the app calls this again whenever a grant changes.
    func start() {
        stop()
        let mask: CGEventMask = [CGEventType.keyDown, .keyUp, .flagsChanged]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let swallow = MainActor.assumeIsolated {
                Unmanaged<Hotkey>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        let info = Unmanaged.passUnretained(self).toOpaque()
        for option in [CGEventTapOptions.defaultTap, .listenOnly] {
            if let created = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: option,
                eventsOfInterest: mask, callback: callback, userInfo: info
            ) {
                tap = created
                break
            }
        }
        guard let tap else {
            print("hotkey: no event tap; grant Input Monitoring and Accessibility")
            return
        }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        panel.hasTap = true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        fnHeld = false
        swallowedKeyUps = []
        panel.hasTap = false
    }

    /// Returns true to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .keyDown where code == Self.escapeKeyCode:
            return swallowingKeyUp(code, panel.escape())
        case .keyDown where fnHeld:
            return swallowingKeyUp(code, engine.send(.key(.keyDown(code: Int(code)))) == .handled)
        case .keyUp:
            return swallowedKeyUps.remove(code) != nil
        case .flagsChanged:
            guard let key = flagKey(code: code, flags: event.flags) else { return false }
            return engine.send(.key(key)) == .handled
        default:
            return false
        }
    }

    private func swallowingKeyUp(_ code: Int64, _ handled: Bool) -> Bool {
        if handled { swallowedKeyUps.insert(code) }
        return handled
    }

    private func flagKey(code: Int64, flags: CGEventFlags) -> Key? {
        if code == Self.fnKeyCode {
            let down = flags.contains(.maskSecondaryFn)
            guard down != fnHeld else { return nil }
            fnHeld = down
            return down ? .fnDown(shift: flags.contains(.maskShift)) : .fnUp
        }
        if Self.shiftKeyCodes.contains(code), fnHeld, flags.contains(.maskShift) { return .shiftDown }
        return nil
    }
}
