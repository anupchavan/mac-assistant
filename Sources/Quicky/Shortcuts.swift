import AppKit
import CoreGraphics

/// The one key Quicky listens to. Every gesture is a modifier on its own (hold, double-tap, ⇧ or ⌥ with
/// it), so none can clash with a Raycast hotkey: Raycast needs a non-modifier key in every hotkey.
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightCommand, hyper, control, rightOption, fn

    /// Right ⌘: does nothing on its own in macOS, sits under the right thumb for holding, and isn't
    /// taken by Wispr Flow (fn), Claude (⌥ ⌥) or ChatGPT (⌥ Space).
    static let defaultKey = TriggerKey.rightCommand
    static let defaultsKey = "triggerKey"
    static var chosen: TriggerKey {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(TriggerKey.init) ?? defaultKey
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightCommand: return "Right Command"
        case .hyper: return "Hyperkey"
        case .control: return "Control"
        case .rightOption: return "Right Option"
        case .fn: return "fn"
        }
    }

    /// Shown on key caps and hints.
    var symbol: String {
        switch self {
        case .rightCommand: return "⌘"
        case .hyper: return "✧"
        case .control: return "⌃"
        case .rightOption: return "⌥"
        case .fn: return "fn"
        }
    }

    var note: String {
        switch self {
        case .rightCommand: return "Free on its own in macOS, and under your thumb. Left ⌘ shortcuts are untouched."
        case .hyper: return "⌘⌃⌥⇧ pressed as one key, usually Caps Lock. Hyper + letter shortcuts in Raycast keep working."
        case .control: return "Either Control key. ⌃ shortcuts are untouched, but a fast ⌃ ⌃ can start listening by accident."
        case .rightOption: return "Free on US layouts. Other layouts type accented letters with it."
        case .fn: return "Wispr Flow and macOS dictation also use fn, so they will fire together."
        }
    }

    /// flagsChanged key codes for this key (hyper has none: it is detected from the flags).
    var keyCodes: Set<Int64> {
        switch self {
        case .rightCommand: return [54]
        case .rightOption: return [61]
        case .control: return [59, 62]
        case .fn: return [63]
        case .hyper: return []
        }
    }

    /// Whether this key is down, from the flags of its own flagsChanged event.
    func isDown(_ flags: CGEventFlags) -> Bool {
        switch self {
        case .rightCommand: return flags.rawValue & 0x10 != 0       // NX_DEVICERCMDKEYMASK
        case .rightOption: return flags.rawValue & 0x40 != 0        // NX_DEVICERALTKEYMASK
        case .control: return flags.contains(.maskControl)
        case .fn: return flags.contains(.maskSecondaryFn)
        case .hyper: return false
        }
    }

    /// Modifiers this key itself sets, which therefore don't count as held with it.
    var ownFlags: CGEventFlags {
        switch self {
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .control: return .maskControl
        case .fn: return .maskSecondaryFn
        case .hyper: return HyperDetector.all
        }
    }
}

/// Hyperkey without knowing who makes it. Karabiner (and Raycast's Hyper Key) post ⌘⌃⌥⇧ as a burst
/// a few ms apart; a person pressing them by hand takes far longer. A modifier that was already down
/// before the burst is held *with* Hyper, so ⇧ then Caps Lock reads as ⇧ + Hyper.
struct HyperDetector {
    static let all: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    static let burstMs: Double = 50
    enum Event: Equatable { case down(extra: FnGesture.Extra?), up }

    private var since: [UInt64: Double] = [:]
    private var burst: CGEventFlags = []
    private(set) var isDown = false

    mutating func flags(_ flags: CGEventFlags, at t: Double) -> Event? {
        let mods = flags.intersection(Self.all)
        for m in [CGEventFlags.maskCommand, .maskControl, .maskAlternate, .maskShift] {
            if mods.contains(m) { if since[m.rawValue] == nil { since[m.rawValue] = t } } else { since[m.rawValue] = nil }
        }
        if isDown {
            guard !mods.isSuperset(of: burst) else { return nil }
            isDown = false; burst = []
            return .up
        }
        guard mods == Self.all else { return nil }
        let newest = since.values.max() ?? t
        let inBurst = Self.all.elements.filter { (since[$0.rawValue] ?? 0) >= newest - Self.burstMs }
        guard inBurst.count >= 3 else { return nil }
        burst = CGEventFlags(inBurst)
        isDown = true
        let held = Self.all.subtracting(burst)
        return .down(extra: held.contains(.maskShift) ? .shift : held.contains(.maskAlternate) ? .option : nil)
    }
}

private extension CGEventFlags {
    init(_ list: [CGEventFlags]) { self = list.reduce(into: []) { $0.formUnion($1) } }
    var elements: [CGEventFlags] { [.maskCommand, .maskControl, .maskAlternate, .maskShift].filter { contains($0) } }
}

/// Quicky's own Hyperkey, for Macs without Karabiner: Caps Lock is remapped to F18 with hidutil, and the
/// event tap turns F18 into Hyper (a trigger on its own, ⌘⌃⌥⇧ on any key pressed with it).
enum CapsLockHyper {
    static let defaultsKey = "capsLockHyper"
    static let f18KeyCode: Int64 = 79
    private static let capsLock: UInt64 = 0x7_0000_0039
    private static let f18: UInt64 = 0x7_0000_006D

    static var enabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) && externalSource == nil }

    /// Something else already turns Caps Lock into Hyper; Quicky then only listens.
    static var externalSource: String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/karabiner/karabiner.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("\"caps_lock\"") else { return nil }
        return "Karabiner-Elements"
    }

    /// Adds or removes only our Caps Lock → F18 pair, keeping any other hidutil mappings.
    static func apply(_ on: Bool) {
        var pairs = currentMappings().filter { $0.src != capsLock }
        if on { pairs.append((capsLock, f18)) }
        let json = "{\"UserKeyMapping\":[" + pairs.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}"
        }.joined(separator: ",") + "]}"
        _ = hidutil(["property", "--set", json])
        Log.info("caps lock hyperkey \(on ? "on" : "off")")
    }

    private static func currentMappings() -> [(src: UInt64, dst: UInt64)] {
        let out = hidutil(["property", "--get", "UserKeyMapping"])
        let num = { (key: String, block: Substring) -> UInt64? in
            guard let r = block.range(of: "\(key) = ") else { return nil }
            return UInt64(block[r.upperBound...].prefix { $0.isNumber })
        }
        return out.split(separator: "}").compactMap { block in
            guard let s = num("HIDKeyboardModifierMappingSrc", block), let d = num("HIDKeyboardModifierMappingDst", block) else { return nil }
            return (s, d)
        }
    }

    @discardableResult
    private static func hidutil(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { Log.error("hidutil: \(error.localizedDescription)"); return "" }
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
