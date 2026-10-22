import AppKit
import ApplicationServices

/// Computer use through OpenAI's Responses API (prompts.md §11). Sarvam decides and talks; this clicks.
final class ComputerUser {
    struct Handoff {
        var task: String
        var target: String
        var consequential: Bool
        var confirmText: String
        var spokenTemplate: String
    }

    /// `done` carries the model's own words and how many actions it actually took.
    enum Outcome { case done(String, actions: Int), stopped(String), failed(String) }

    static let maxActions = 15
    static let maxSeconds: TimeInterval = 90

    var onStatus: ((String) -> Void)?
    private(set) var stopRequested = false
    private var stopReason = ""
    weak var monitor: HotkeyMonitor?

    private var inflight: Task<[String: Any], Error>?
    /// True once the agent has done something on screen (not just looked). Before that, your mouse is yours.
    private(set) var hasActed = false

    /// Esc / mouse: takes effect immediately, including while waiting for the model (the request is cancelled).
    func stop(_ reason: String) {
        guard !stopRequested else { return }
        stopRequested = true; stopReason = reason
        inflight?.cancel()
        Log.info("cua stop: \(reason)")
    }

    // MARK: Handoff (Sarvam turns the ask into one instruction)

    /// .failure carries a question for the user, not an error.
    enum HandoffResult { case success(Handoff), failure(String) }

    static func handoff(ask: String, context: ScreenContext, language: String?) async throws -> HandoffResult {
        let messages: [[String: Any]] = [
            ["role": "system", "content": Prompts.handoff],
            ["role": "user", "content": context.block(language: language, outputMode: "typed", includeOCR: true) + "\n\nASK: \(ask)"],
        ]
        let model = Keys.setting("ASSISTANT_DEEP_MODEL", default: "sarvam-105b")
        let text = try await SarvamChat.complete(model: model, messages: messages, reasoning: nil, maxTokens: 400)
        guard let obj = parseJSON(text) else { return .failure("I couldn't work out what to click.") }
        if let q = obj["ask_user"] as? String { return .failure(q) }
        return .success(Handoff(task: obj["task"] as? String ?? ask,
                                target: obj["target"] as? String ?? "",
                                consequential: obj["consequential"] as? Bool ?? true,
                                confirmText: obj["confirm_text"] as? String ?? "Do it",
                                spokenTemplate: obj["spoken_result_template"] as? String ?? ""))
    }

    static func parseJSON(_ text: String) -> [String: Any]? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any]
    }

    // MARK: The loop

    private var targetPid: pid_t = 0

    func run(task: String, pid: pid_t) async -> Outcome {
        targetPid = pid
        defer { Task { @MainActor in AgentCursor.shared.hide() } }
        guard let key = Keys.openAI else { return .failed(MissingKey.openAI.localizedDescription) }
        let started = Date()
        var model = Keys.setting("ASSISTANT_CUA_MODEL", default: "gpt-6-astra")
        let fallbackModel = Keys.setting("ASSISTANT_CUA_FALLBACK_MODEL", default: "gpt-6.1-sol")
        var actions = 0

        guard var shot = await ContextCapture.screenshot(pid: pid), let firstURL = ContextCapture.pngDataURL(shot.0) else {
            return .failed("I can't see the window. Allow Screen Recording in System Settings.")
        }
        Log.info("cua first screenshot \(shot.0.width)×\(shot.0.height), \(firstURL.utf8.count / 1024) KB")
        var body: [String: Any] = [
            "model": model,
            "tools": [["type": "computer"]],
            "reasoning": ["effort": "low"],
            "instructions": Prompts.astraInstructions,
            "truncation": "auto",
            "input": [["role": "user", "content": [
                ["type": "input_text", "text": task],
                ["type": "input_image", "image_url": firstURL, "detail": "original"],
            ]]],
        ]
        var triedFallback = false

        while true {
            if stopRequested { return .stopped(stopReason) }
            if Date().timeIntervalSince(started) > Self.maxSeconds { return .stopped("took too long") }
            onStatus?("Thinking")
            let response: [String: Any]
            let tr = Date()
            do {
                let request = Task { [body] in try await Self.post(body, key: key) }
                inflight = request
                response = try await request.value
                inflight = nil
                Log.time("cua \(model) step \(actions + 1) round trip", since: tr)
            } catch is CancellationError {
                Log.time("cua \(model) cancelled while waiting", since: tr)
                return .stopped(stopReason.isEmpty ? "stopped" : stopReason)
            } catch let e as URLError where e.code == .cancelled {
                return .stopped(stopReason.isEmpty ? "stopped" : stopReason)
            } catch let e as APIError where !triedFallback && (e.status == 404 || e.status == 400 || e.status == 403) && body["previous_response_id"] == nil {
                Log.error("cua \(model) refused (\(e.status)); retrying with fallback model")
                triedFallback = true
                model = fallbackModel
                body["model"] = model
                continue
            } catch {
                return .failed(error.localizedDescription)
            }
            guard let id = response["id"] as? String else { return .failed("No response id") }
            let output = response["output"] as? [[String: Any]] ?? []
            let calls = output.filter { ($0["type"] as? String) == "computer_call" }
            if calls.isEmpty {
                let text = output.compactMap { item -> String? in
                    guard (item["type"] as? String) == "message" else { return nil }
                    return (item["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
                }.joined(separator: " ")
                Log.info("cua \(model) finished after \(actions) action(s): \(text.prefix(160))")
                return .done(text, actions: actions)
            }
            var outputs: [[String: Any]] = []
            for call in calls {
                let callID = call["call_id"] as? String ?? ""
                var acts = call["actions"] as? [[String: Any]] ?? []
                if acts.isEmpty, let single = call["action"] as? [String: Any] { acts = [single] }
                Self.saveDebugFrame(shot.0, actions: acts, step: actions + 1)
                for act in acts {
                    if stopRequested { return .stopped(stopReason) }
                    actions += 1
                    if (act["type"] as? String) != "screenshot" { hasActed = true }
                    Log.info("cua action \(actions): \(act["type"] as? String ?? "?")")
                    if actions > Self.maxActions { return .stopped("too many steps") }
                    let (ok, why) = await execute(act, windowFrame: shot.1, imageSize: CGSize(width: shot.0.width, height: shot.0.height))
                    if !ok { return .stopped(why) }
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let next = await ContextCapture.screenshot(pid: pid), let url = ContextCapture.pngDataURL(next.0) else {
                    return .failed("Lost sight of the window.")
                }
                shot = next
                var out: [String: Any] = ["type": "computer_call_output", "call_id": callID,
                                          "output": ["type": "computer_screenshot", "image_url": url, "detail": "original"]]
                if let checks = call["pending_safety_checks"] as? [[String: Any]], !checks.isEmpty {
                    out["acknowledged_safety_checks"] = checks   // the user confirmed the task before the run
                }
                outputs.append(out)
            }
            body["previous_response_id"] = id
            body["input"] = outputs
        }
    }

    static func post(_ body: [String: Any], key: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError(status: status, body: String(data: data, encoding: .utf8) ?? "", provider: .openAI) }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: Debug frames (opt-in: defaults write dev.anup.assistant cuaDebug -bool true)

    static var debugDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.anup.assistant/cua-debug", isDirectory: true)
    }

    /// The screenshot the agent acted on, with a red ring where each action lands. Local only, overwritten each run.
    static func saveDebugFrame(_ img: CGImage, actions: [[String: Any]], step: Int) {
        guard UserDefaults.standard.bool(forKey: "cuaDebug") else { return }
        if step == 1 { try? FileManager.default.removeItem(at: debugDir) }
        try? FileManager.default.createDirectory(at: debugDir, withIntermediateDirectories: true)
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.setStrokeColor(red: 1, green: 0.1, blue: 0.1, alpha: 1); ctx.setLineWidth(4)
        for a in actions {
            guard let x = (a["x"] as? NSNumber)?.doubleValue, let y = (a["y"] as? NSNumber)?.doubleValue else { continue }
            ctx.strokeEllipse(in: CGRect(x: x - 14, y: Double(img.height) - y - 14, width: 28, height: 28))
        }
        guard let out = ctx.makeImage() else { return }
        let names = actions.compactMap { $0["type"] as? String }.joined(separator: "+")
        let url = debugDir.appendingPathComponent(String(format: "step-%02d-%@.png", step, names))
        try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Executor (CGEvents, mapped from screenshot pixels to screen points)

    /// point = windowOrigin + (x, y) / scale. Refuses anything outside the window.
    static func map(_ x: Double, _ y: Double, windowFrame: CGRect, imageSize: CGSize) -> CGPoint? {
        guard imageSize.width > 0 else { return nil }
        let scale = imageSize.width / windowFrame.width
        let p = CGPoint(x: windowFrame.minX + x / scale, y: windowFrame.minY + y / scale)
        return windowFrame.insetBy(dx: -1, dy: -1).contains(p) ? p : nil
    }

    private func execute(_ act: [String: Any], windowFrame: CGRect, imageSize: CGSize) async -> (Bool, String) {
        let type = act["type"] as? String ?? ""
        func num(_ k: String) -> Double { (act[k] as? NSNumber)?.doubleValue ?? 0 }
        func point() -> CGPoint? { Self.map(num("x"), num("y"), windowFrame: windowFrame, imageSize: imageSize) }
        monitor?.syntheticDepth += 1
        defer { monitor?.syntheticDepth -= 1 }
        let src = HotkeyMonitor.syntheticSource(.hidSystemState)
        // Keys go straight to the target app if you've moved on to another one; otherwise the normal way.
        let keyTarget: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid ? nil : targetPid
        switch type {
        case "click", "double_click":
            guard let p = point() else { return (false, "a click outside the window") }
            let label = Self.label(at: p)
            onStatus?("Clicking \(label ?? "")".trimmingCharacters(in: .whitespaces))
            await AgentCursor.shared.move(to: p, label: label.map { "Clicking \($0)" } ?? "Clicking")
            await MainActor.run { AgentCursor.shared.click() }
            let button = (act["button"] as? String) ?? "left"
            // Background first: press the element through accessibility, the real cursor never moves.
            if type == "click", button == "left", let how = Self.axPress(at: p, pid: targetPid) {
                Log.info(String(format: "cua click (%.0f, %.0f) on \"%@\" via accessibility (%@)", p.x, p.y, label ?? "?", how))
            } else {
                Log.info(String(format: "cua click (%.0f, %.0f) on \"%@\" via mouse events", p.x, p.y, label ?? "?"))
                await Self.hidClick(at: p, count: type == "double_click" ? 2 : 1, right: button == "right", src: src)
            }
        case "move":
            guard let p = point() else { return (false, "a move outside the window") }
            await AgentCursor.shared.move(to: p, label: "")
        case "scroll":
            guard let p = point() else { return (false, "a scroll outside the window") }
            onStatus?("Scrolling")
            await AgentCursor.shared.move(to: p, label: "Scrolling")
            let saved = CGEvent(source: nil)?.location
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            let dy = Int32(-num("scroll_y") / 10), dx = Int32(-num("scroll_x") / 10)
            CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy * 10, wheel2: dx * 10, wheel3: 0)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 40_000_000)
            Self.restoreCursor(saved)
        case "drag":
            let path = (act["path"] as? [[String: Any]]) ?? []
            let pts = path.compactMap { Self.map(($0["x"] as? NSNumber)?.doubleValue ?? 0, ($0["y"] as? NSNumber)?.doubleValue ?? 0, windowFrame: windowFrame, imageSize: imageSize) }
            guard pts.count >= 2, pts.count == path.count else { return (false, "a drag outside the window") }
            onStatus?("Dragging")
            await AgentCursor.shared.move(to: pts[0], label: "Dragging")
            let savedDrag = CGEvent(source: nil)?.location
            defer { Self.restoreCursor(savedDrag) }
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pts[0], mouseButton: .left)?.post(tap: .cghidEventTap)
            for p in pts.dropFirst() {
                CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pts.last!, mouseButton: .left)?.post(tap: .cghidEventTap)
        case "type":
            onStatus?("Typing")
            let text = act["text"] as? String ?? ""
            var rest = Substring(text)
            while !rest.isEmpty {
                if stopRequested { return (false, stopReason) }
                let chunk = Array(rest.prefix(20).utf16)
                rest = rest.dropFirst(min(20, rest.count))
                let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
                let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
                d?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                u?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                if let pid = keyTarget { d?.postToPid(pid); u?.postToPid(pid) } else { d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap) }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        case "keypress":
            let keys = (act["keys"] as? [String]) ?? []
            onStatus?("Pressing \(keys.joined(separator: " "))")
            Self.pressKeys(keys, src: src, toPid: keyTarget)
        case "wait":
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        case "screenshot":
            break
        default:
            Log.error("cua: unknown action \(type)")
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        return (true, "")
    }

    private func pressKeys(_ keys: [String], src: CGEventSource?) { Self.pressKeys(keys, src: src) }

    /// Posts one key combo (["cmd", "w"]). With a pid it goes straight to that app, so our key panel can't eat it.
    @discardableResult
    static func pressKeys(_ keys: [String], src: CGEventSource?, toPid pid: pid_t? = nil) -> Bool {
        var flags: CGEventFlags = []
        var main: CGKeyCode?
        for k in keys {
            switch k.uppercased() {
            case "CMD", "COMMAND", "META", "SUPER": flags.insert(.maskCommand)
            case "CTRL", "CONTROL": flags.insert(.maskControl)
            case "ALT", "OPTION": flags.insert(.maskAlternate)
            case "SHIFT": flags.insert(.maskShift)
            default: main = Self.keyCode(k)
            }
        }
        guard let code = main else { return false }
        let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        d?.flags = flags; u?.flags = flags
        if let pid { d?.postToPid(pid); u?.postToPid(pid) } else { d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap) }
        return true
    }

    static func keyCode(_ k: String) -> CGKeyCode? {
        let named: [String: CGKeyCode] = ["ENTER": 36, "RETURN": 36, "TAB": 48, "SPACE": 49, "BACKSPACE": 51, "DELETE": 51,
                                          "ESC": 53, "ESCAPE": 53, "LEFT": 123, "RIGHT": 124, "DOWN": 125, "UP": 126,
                                          "ARROWLEFT": 123, "ARROWRIGHT": 124, "ARROWDOWN": 125, "ARROWUP": 126,
                                          "HOME": 115, "END": 119, "PAGEUP": 116, "PAGEDOWN": 121, "FORWARDDELETE": 117,
                                          "F": 3, "[": 33, "]": 30, "=": 24, "PLUS": 24, "-": 27, "MINUS": 27, ";": 41, "'": 39, "\\": 42, "`": 50]
        if let c = named[k.uppercased()] { return c }
        let letters: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
                                               "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20,
                                               "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
                                               "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "/": 44, ".": 47, ",": 43]
        if k.count == 1, let c = letters[Character(k.lowercased())] { return c }
        return nil
    }

    /// Press the element at `p` through accessibility, so the real cursor never moves. Walks up from the
    /// hit element (text inside a link, an icon inside a button) to something pressable; text fields get
    /// focus instead. Returns how it acted, or nil when this element needs a real click.
    static func axPress(at p: CGPoint, pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success, var el = hit else { return nil }
        let pressable: Set<String> = ["AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXCheckBox", "AXRadioButton",
                                      "AXPopUpButton", "AXDisclosureTriangle", "AXMenuBarItem"]
        let editable: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        for _ in 0..<6 {
            let role: String = ContextCapture.attr(el, kAXRoleAttribute) ?? ""
            if editable.contains(role) {
                return AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success ? "focus \(role)" : nil
            }
            if pressable.contains(role) {
                var names: CFArray?
                guard AXUIElementCopyActionNames(el, &names) == .success, ((names as? [String]) ?? []).contains(kAXPressAction),
                      AXUIElementPerformAction(el, kAXPressAction as CFString) == .success else { return nil }
                return "press \(role)"
            }
            guard let parent: AXUIElement = ContextCapture.attr(el, kAXParentAttribute) else { return nil }
            el = parent
        }
        return nil
    }

    /// A real click (hover, press, release like a hand; web apps ignore instant clicks), then the user's
    /// cursor goes straight back to where it was.
    static func hidClick(at p: CGPoint, count: Int, right: Bool, src: CGEventSource?) async {
        let saved = CGEvent(source: nil)?.location
        let (downT, upT, btn): (CGEventType, CGEventType, CGMouseButton) = right
            ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 80_000_000)
        for i in 1...count {
            let d = CGEvent(mouseEventSource: src, mouseType: downT, mouseCursorPosition: p, mouseButton: btn)
            let u = CGEvent(mouseEventSource: src, mouseType: upT, mouseCursorPosition: p, mouseButton: btn)
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            d?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 50_000_000)
            u?.post(tap: .cghidEventTap)
            if i < count { try? await Task.sleep(nanoseconds: 60_000_000) }
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        restoreCursor(saved)
    }

    static func restoreCursor(_ p: CGPoint?) {
        guard let p else { return }
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// AX label of the element at a point, so the pill says "Clicking Block" instead of coordinates.
    static func label(at p: CGPoint) -> String? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success, let el else { return nil }
        let t: String? = ContextCapture.attr(el, kAXTitleAttribute) ?? ContextCapture.attr(el, kAXDescriptionAttribute) ?? (ContextCapture.attr(el, kAXValueAttribute) as String?)
        guard let t, !t.isEmpty else { return nil }
        return String(t.prefix(30))
    }
}
