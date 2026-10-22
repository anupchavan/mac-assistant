import AppKit
import ApplicationServices

/// A button, toggle or menu in the focused window, read through accessibility so the model can press it
/// by number: no screenshot, no vision model, no mouse. Pressing is an AXPress (a few ms); only when an
/// element refuses that does it get a real click at its centre.
struct Control {
    let id: Int
    let role: String          // "button", "checkbox", "tab", "menu button", …
    let label: String
    let state: String         // "on" / "off" for toggles, else ""
    let element: AXUIElement
    let frame: CGRect?

    var line: String { "\(id) | \(role) | \(label)\(state.isEmpty ? "" : " (\(state))")" }

    /// Pressing these changes something for good or for other people, so the confirm card asks first.
    var consequential: Bool {
        label.range(of: #"(?i)\b(block|delete|remove|send|post|publish|buy|pay|order|purchase|unsubscribe|report|unfollow|sign out|log ?out|discard|erase|empty trash|submit|transfer|leave)\b"#,
                    options: .regularExpression) != nil
    }
}

enum Controls {
    /// The latest capture's controls by id, for the press tool. Replaced on every capture.
    static let latest = Locked<[Int: Control]>([:])

    static let roles: [String: String] = [
        "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXPopUpButton": "popup",
        "AXMenuButton": "menu button", "AXDisclosureTriangle": "disclosure", "AXTab": "tab", "AXSwitch": "switch",
        "AXToggle": "toggle", "AXComboBox": "combo box",
    ]

    /// Visible controls of the focused window in reading order: native ones by a bounded walk, a web page's
    /// through WebKit/Chromium's control search (one call). Gives up quietly at the deadline.
    static func harvest(pid: pid_t, deadline seconds: TimeInterval = 0.15, limit: Int = 120) async -> [Control] {
        await Task.detached(priority: .userInitiated) { () -> [Control] in
            guard AXIsProcessTrusted() else { return [] }
            let t0 = Date()
            let deadline = t0.addingTimeInterval(seconds)
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            guard let win: AXUIElement = ContextCapture.attr(app, kAXFocusedWindowAttribute) else { return [] }
            var found: [AXUIElement] = []
            var webAreas: [AXUIElement] = []

            // Native walk, breadth-first, not descending into web content.
            var queue = [win]
            var seen = 0
            while !queue.isEmpty, seen < 1500, found.count < limit, Date() < deadline {
                let el = queue.removeFirst()
                seen += 1
                AXUIElementSetMessagingTimeout(el, 0.05)
                let role: String = ContextCapture.attr(el, kAXRoleAttribute) ?? ""
                if role == "AXWebArea" { webAreas.append(el); continue }
                if roles[role] != nil { found.append(el) }
                if role == "AXMenuBar" { continue }
                if let kids: [AXUIElement] = ContextCapture.attr(el, kAXVisibleChildrenAttribute) ?? ContextCapture.attr(el, kAXChildrenAttribute) {
                    queue += kids.prefix(60)
                }
            }
            // Web content: buttons and other controls currently on screen.
            for web in webAreas.prefix(1) where Date() < deadline {
                AXUIElementSetMessagingTimeout(web, 0.15)
                for key in ["AXControlSearchKey", "AXButtonSearchKey"] {
                    let predicate: [String: Any] = ["AXSearchKey": key, "AXResultsLimit": limit, "AXDirection": "AXDirectionNext",
                                                    "AXVisibleOnly": true, "AXImmediateDescendantsOnly": false]
                    var out: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(web, "AXUIElementsForSearchPredicate" as CFString, predicate as CFDictionary, &out) == .success,
                       let els = out as? [AXUIElement], !els.isEmpty { found += els; break }
                }
            }

            var controls: [Control] = []
            var keys = Set<String>()
            let names = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] as CFArray
            for el in found where Date() < deadline.addingTimeInterval(0.05) && controls.count < limit {
                AXUIElementSetMessagingTimeout(el, 0.05)
                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(el, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                      let v = values as? [Any], v.count == 5, let axRole = v[0] as? String, let role = roles[axRole] else { continue }
                var label = [v[1], v[2], v[4]].compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
                if label.isEmpty { label = childText(el) }
                guard !label.isEmpty else { continue }
                label = String(label.replacingOccurrences(of: "\n", with: " ").prefix(60))
                var state = ""
                if ["checkbox", "switch", "toggle", "radio"].contains(role), let n = v[3] as? NSNumber { state = n.intValue == 0 ? "off" : "on" }
                guard keys.insert("\(role)|\(label)").inserted else { continue }
                controls.append(Control(id: controls.count + 1, role: role, label: label, state: state, element: el, frame: ContextCapture.frame(of: el)))
            }
            latest.value = Dictionary(uniqueKeysWithValues: controls.map { ($0.id, $0) })
            Log.info(String(format: "controls %d (of %d found) in %.0f ms", controls.count, found.count, Date().timeIntervalSince(t0) * 1000))
            return controls
        }.value
    }

    /// Icon buttons often carry their name on a child ("Follow" text inside the button).
    private static func childText(_ el: AXUIElement) -> String {
        guard let kids: [AXUIElement] = ContextCapture.attr(el, kAXChildrenAttribute) else { return "" }
        for k in kids.prefix(4) {
            AXUIElementSetMessagingTimeout(k, 0.03)
            let s: String = (ContextCapture.attr(k, kAXValueAttribute) as String?) ?? ContextCapture.attr(k, kAXTitleAttribute) ?? ContextCapture.attr(k, kAXDescriptionAttribute) ?? ""
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return ""
    }

    /// AXPress first; a real click at the centre only if the element won't take it. Returns a result for the model.
    static func press(_ id: Int, pid: pid_t?) async -> String {
        guard let c = latest.value[id] else { return "error: no control \(id) on screen now" }
        AXUIElementSetMessagingTimeout(c.element, 0.3)
        if AXUIElementPerformAction(c.element, kAXPressAction as CFString) == .success {
            return "pressed \(c.role) “\(c.label)”"
        }
        guard let f = c.frame, f.width > 0 else { return "error: \(c.role) “\(c.label)” can't be pressed" }
        if let pid, let app = NSRunningApplication(processIdentifier: pid) { await MainActor.run { FocusMove.begin(); _ = app.activate() } }
        await ComputerUser.hidClick(at: CGPoint(x: f.midX, y: f.midY), count: 1, right: false, src: HotkeyMonitor.syntheticSource(.combinedSessionState))
        return "clicked \(c.role) “\(c.label)”"
    }

    static func id(_ call: ToolCall) -> Int {
        (call.arguments["id"] as? NSNumber)?.intValue ?? Int(call.string("id")) ?? 0
    }

    /// The CONTROLS block: at most `max` lines.
    static func lines(_ controls: [Control], max: Int = 80) -> String {
        controls.prefix(max).map(\.line).joined(separator: "\n")
    }
}
