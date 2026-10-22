import AppKit
import ApplicationServices

/// Reading the user's selected text when the focused element doesn't expose it.
/// Order (same as Raycast): Accessibility → turn on the app's manual accessibility and read again →
/// copy with ⌘C and put the clipboard back.
enum Selection {
    private static var manualOn = Set<pid_t>()

    /// Chrome and Electron apps build their accessibility tree only when asked. Setting
    /// AXManualAccessibility asks for it without the side effects of AXEnhancedUserInterface
    /// (which breaks window animations). Returns true the first time, when a re-read is worth trying.
    static func enableManualAccessibility(pid: pid_t) -> Bool {
        guard pid != 0, !manualOn.contains(pid) else { return false }
        manualOn.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        let ok = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        Log.info("selection: manual accessibility for pid \(pid) \(ok ? "on" : "not supported")")
        return ok
    }

    /// ⌘C into the app, read the copied text, then restore whatever was on the clipboard.
    /// Nil when nothing was copied within the wait (no selection, or the app ignored ⌘C).
    @MainActor
    static func viaClipboard(pid: pid_t, wait: TimeInterval = 0.3) async -> String? {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        let before = pb.changeCount
        let t0 = Date()
        guard ComputerUser.pressKeys(["cmd", "c"], src: HotkeyMonitor.syntheticSource(.combinedSessionState), toPid: pid) else { return nil }
        while pb.changeCount == before, Date().timeIntervalSince(t0) < wait {
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        guard pb.changeCount != before else {
            Log.info("selection: clipboard fallback copied nothing")
            return nil
        }
        let text = pb.string(forType: .string)
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
        Log.time("selection: clipboard fallback \(text?.count ?? 0) chars", since: t0)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
