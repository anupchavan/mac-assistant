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
    /// Identity across two reads of the window (ids are renumbered every read).
    var key: String { "\(role)|\(label)|\(state)" }

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
        "AXToggle": "toggle", "AXComboBox": "combo box", "AXTextField": "text field", "AXTextArea": "text area",
        "AXSearchField": "search field",
    ]
    static let textRoles: Set<String> = ["text field", "text area", "combo box", "search field"]

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
            // Web content: buttons, text fields and other controls on screen. Each search key catches things
            // the others miss (a div with role=button in a modal is a button but not always a "control"),
            // so take all of them; duplicates collapse below. A key may list several element types at once.
            for web in webAreas.prefix(1) where Date() < deadline {
                AXUIElementSetMessagingTimeout(web, 0.15)
                let predicate: [String: Any] = ["AXSearchKey": ["AXControlSearchKey", "AXButtonSearchKey", "AXTextFieldSearchKey"],
                                                "AXResultsLimit": limit * 2, "AXDirection": "AXDirectionNext",
                                                "AXVisibleOnly": true, "AXImmediateDescendantsOnly": false]
                var out: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(web, "AXUIElementsForSearchPredicate" as CFString, predicate as CFDictionary, &out) == .success,
                   let els = out as? [AXUIElement] { found += els }
                else {
                    for key in ["AXControlSearchKey", "AXButtonSearchKey", "AXTextFieldSearchKey"] where Date() < deadline {
                        var one = predicate; one["AXSearchKey"] = key
                        var o: CFTypeRef?
                        if AXUIElementCopyParameterizedAttributeValue(web, "AXUIElementsForSearchPredicate" as CFString, one as CFDictionary, &o) == .success,
                           let els = o as? [AXUIElement] { found += els }
                    }
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
                let subrole: String = ContextCapture.attr(el, kAXSubroleAttribute) ?? ""
                if ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"].contains(subrole) { continue }
                var kind = role
                if subrole == "AXSearchField" { kind = "search field" }
                if textRoles.contains(kind) {
                    let placeholder: String = ContextCapture.attr(el, "AXPlaceholderValue") ?? ""
                    let typed = (v[3] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    label = [label, placeholder].first { !$0.isEmpty } ?? ""
                    if !typed.isEmpty { label += label.isEmpty ? "“\(typed.prefix(40))”" : " (has “\(typed.prefix(40))”)" }
                }
                if label.isEmpty { label = childText(el) }
                guard !label.isEmpty else { continue }
                // Hidden parts (a closed find bar) still sit in the tree with no size.
                let frame = ContextCapture.frame(of: el)
                if let f = frame, f.width < 1 || f.height < 1 { continue }
                label = String(label.replacingOccurrences(of: "\n", with: " ").prefix(60))
                var state = ""
                if ["checkbox", "switch", "toggle", "radio"].contains(role), let n = v[3] as? NSNumber { state = n.intValue == 0 ? "off" : "on" }
                guard keys.insert("\(kind)|\(label)|\(frame.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "")").inserted else { continue }
                controls.append(Control(id: controls.count + 1, role: kind, label: label, state: state, element: el, frame: frame))
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

    /// Marker in a press result: what follows is a menu or dialog the press opened, for the model's next step.
    static let openedMarker = "\nIT OPENED (press one of these next if the ask needs it):\n"
    static let unchangedMarker = ", but nothing on screen changed"

    /// AXPress first; a real click at the centre only if the element won't take it. Then the window is read
    /// again, so the result says what the press did: opened a menu or dialog (listed, for a second press like
    /// Instagram's Following → Unfollow), changed the screen, or changed nothing.
    static func press(_ id: Int, pid: pid_t?) async -> String {
        guard let c = latest.value[id] else { return "error: no control \(id) on screen now" }
        let before = Set(latest.value.values.map(\.key))
        AXUIElementSetMessagingTimeout(c.element, 0.3)
        var did = "pressed \(c.role) “\(c.label)”"
        if AXUIElementPerformAction(c.element, kAXPressAction as CFString) != .success {
            guard let f = c.frame, f.width > 0 else { return "error: \(c.role) “\(c.label)” can't be pressed" }
            if let pid, let app = NSRunningApplication(processIdentifier: pid) { await MainActor.run { FocusMove.begin(); _ = app.activate() } }
            await ComputerUser.hidClick(at: CGPoint(x: f.midX, y: f.midY), count: 1, right: false, src: HotkeyMonitor.syntheticSource(.combinedSessionState))
            did = "clicked \(c.role) “\(c.label)”"
        }
        guard let pid else { return did }
        // Menus and dialogs animate in; look twice before calling it unchanged.
        var fresh: [Control] = []
        for wait in [250, 350] as [UInt64] {
            try? await Task.sleep(nanoseconds: wait * 1_000_000)
            let after = await harvest(pid: pid)
            fresh = after.filter { !before.contains($0.key) }
            if !fresh.isEmpty || !after.contains(where: { $0.key == c.key }) { break }
        }
        if fresh.isEmpty && latest.value.values.contains(where: { $0.key == c.key }) { return did + unchangedMarker }
        if let opened = openedSurface(fresh, pressed: c) { return did + openedMarker + lines(opened, max: 30) }
        return did
    }

    /// The new controls when they sit in a menu, dialog, sheet or popover (checked by walking up a few
    /// parents), or when a menu-like button produced a short list. Nil when the press just changed the page.
    private static func openedSurface(_ fresh: [Control], pressed: Control) -> [Control]? {
        guard !fresh.isEmpty else { return nil }
        let containers: Set<String> = ["AXMenu", "AXSheet", "AXPopover", "AXDialog"]
        let dialogSubroles: Set<String> = ["AXDialog", "AXApplicationDialog", "AXSystemDialog", "AXFloatingWindow", "AXApplicationAlertDialog"]
        for c in fresh.prefix(8) {
            var el = c.element
            for _ in 0..<10 {
                guard let parent: AXUIElement = ContextCapture.attr(el, kAXParentAttribute) else { break }
                AXUIElementSetMessagingTimeout(parent, 0.03)
                let role: String = ContextCapture.attr(parent, kAXRoleAttribute) ?? ""
                let sub: String = ContextCapture.attr(parent, kAXSubroleAttribute) ?? ""
                if containers.contains(role) || dialogSubroles.contains(sub) { return fresh }
                if role == "AXWindow" || role == "AXWebArea" { break }
                el = parent
            }
        }
        let menuish = ["popup", "menu button"].contains(pressed.role)
            || pressed.label.range(of: #"(?i)chevron|more|options|menu|…|\.\.\.|following"#, options: .regularExpression) != nil
        return menuish && fresh.count <= 15 ? fresh : nil
    }

    /// "pressed button “Follow”" → "Follow".
    static func label(from result: String) -> String? {
        guard let a = result.firstIndex(of: "“"), let b = result.lastIndex(of: "”"), a < b else { return nil }
        return String(result[result.index(after: a)..<b])
    }

    /// Focus a text field from CONTROLS, replace what's in it, and press Return when `submit`. Typed as key
    /// events to the app (not AXValue), so web pages see real input events.
    static func type(_ id: Int, text: String, submit: Bool, pid: pid_t?) async -> String {
        guard let c = latest.value[id] else { return "error: no control \(id) on screen now" }
        guard textRoles.contains(c.role) else { return "error: \(c.role) “\(c.label)” isn't a text field; use press" }
        guard let pid else { return "error: no app to type into" }
        AXUIElementSetMessagingTimeout(c.element, 0.3)
        let focused = AXUIElementSetAttributeValue(c.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        if !focused, let f = c.frame {
            await ComputerUser.hidClick(at: CGPoint(x: f.midX, y: f.midY), count: 1, right: false, src: HotkeyMonitor.syntheticSource(.combinedSessionState))
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        let src = HotkeyMonitor.syntheticSource(.combinedSessionState)
        ComputerUser.pressKeys(["cmd", "a"], src: src, toPid: pid)
        typeString(text, src: src, pid: pid)
        if submit {
            try? await Task.sleep(nanoseconds: 80_000_000)
            ComputerUser.pressKeys(["return"], src: src, toPid: pid)
        }
        return "typed “\(text.prefix(60))” into \(c.role) “\(c.label)”\(submit ? " and pressed Return" : "")"
    }

    private static func typeString(_ s: String, src: CGEventSource?, pid: pid_t) {
        var units = Array(s.utf16)[...]
        while !units.isEmpty {
            let chunk = Array(units.prefix(16))
            units = units.dropFirst(chunk.count)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.postToPid(pid)
            }
        }
    }

    static func id(_ call: ToolCall) -> Int {
        (call.arguments["id"] as? NSNumber)?.intValue ?? Int(call.string("id")) ?? 0
    }

    /// The CONTROLS block: at most `max` lines.
    static func lines(_ controls: [Control], max: Int = 80) -> String {
        controls.prefix(max).map(\.line).joined(separator: "\n")
    }
}
