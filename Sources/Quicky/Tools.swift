import AppKit
import EventKit

struct ToolCall: Identifiable {
    let id: String
    let name: String
    let arguments: [String: Any]
    let rawArguments: String

    func string(_ k: String) -> String { arguments[k] as? String ?? "" }

    /// open_url's links: "urls", plus a single "url" (reflexes, and models that send one).
    var urlList: [String] {
        ([string("url")] + ((arguments["urls"] as? [String]) ?? [])).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Needs a confirm card before running (changes or creates data, or a shortcut that can lose work).
    var needsConfirm: Bool {
        if name == "press_shortcut" { return Tools.isDestructive(shortcut: string("keys")) }
        if name == "press" { return Controls.latest.value[Controls.id(self)]?.consequential ?? false }
        // Typing into a search box is harmless; typing into anything else and sending it (a message, a form) asks first.
        if name == "type_text" {
            guard let c = Controls.latest.value[Controls.id(self)] else { return false }
            return arguments["submit"] as? Bool != false && c.role != "search field" && c.label.range(of: #"(?i)search|find|filter|url|address"#, options: .regularExpression) == nil
        }
        return ["create_event", "create_reminder", "move_files", "run_shortcut", "insert_text", "trim_and_merge_videos"].contains(name)
    }

    /// Verb + object for the confirm card's ↵ button, never "OK".
    var confirmVerb: String {
        switch name {
        case "create_event": return "Add to Calendar"
        case "create_reminder": return "Add Reminder"
        case "move_files": return "Move Files"
        case "run_shortcut": return "Run Shortcut"
        case "trim_and_merge_videos": return "Make Video"
        case "insert_text": return "Insert"
        case "press_shortcut": return "Press \(Tools.symbols(string("keys")))"
        case "press": return "Press \(Controls.latest.value[Controls.id(self)]?.label ?? "It")"
        case "type_text": return "Send"
        default: return "Run"
        }
    }

    var confirmTitle: String {
        switch name {
        case "create_event": return "Add “\(string("title"))” to Calendar"
        case "create_reminder": return "Remind you: “\(string("title"))”"
        case "move_files":
            let n = (arguments["paths"] as? [String])?.count ?? 0
            return "Move \(n) file\(n == 1 ? "" : "s") to \((string("destination") as NSString).lastPathComponent)"
        case "run_shortcut": return "Run the shortcut “\(string("name"))”"
        case "trim_and_merge_videos":
            let n = (arguments["clips"] as? [[String: Any]])?.count ?? 0
            return n > 1 ? "Join \(n) videos into one" : "Trim the video"
        case "insert_text": return "Insert text into \(string("app").isEmpty ? "the focused field" : string("app"))"
        case "press_shortcut": return "Press \(Tools.symbols(string("keys")))\(string("app").isEmpty ? "" : " in \(string("app"))")"
        case "press": return "Press “\(Controls.latest.value[Controls.id(self)]?.label ?? "that")”"
        case "type_text": return "Type into “\(Controls.latest.value[Controls.id(self)]?.label ?? "the field")” and send"
        default: return name
        }
    }

    var confirmDetail: String {
        switch name {
        case "type_text": return String(string("text").prefix(160))
        case "create_event":
            return [Tools.humanDate(string("start")), string("end").isEmpty ? "" : "until \(Tools.humanDate(string("end")))"]
                .filter { !$0.isEmpty }.joined(separator: " ")
        case "create_reminder": return Tools.humanDate(string("due"))
        case "move_files": return string("destination")
        case "insert_text": return String(string("text").prefix(160))
        case "trim_and_merge_videos":
            return ((arguments["clips"] as? [[String: Any]]) ?? []).map { c in
                let name = ((c["path"] as? String ?? "") as NSString).lastPathComponent
                let s = Media.seconds(c["start"]), e = Media.seconds(c["end"])
                func t(_ x: Double) -> String { String(format: "%d:%02d", Int(x) / 60, Int(x) % 60) }
                let range = s == nil && e == nil ? "whole" : "\(t(s ?? 0))–\(e.map(t) ?? "end")"
                return "\(name) (\(range))"
            }.joined(separator: " → ")
        default: return string("input")
        }
    }

    /// Status line while running ("Adding to Calendar").
    var statusText: String {
        switch name {
        case "web_search": return "Searching the web for “\(string("query"))”"
        case "open_url":
            let list = urlList
            return list.count > 1 ? "Opening \(list.count) links" : "Opening \(URL(string: list.first ?? "")?.host ?? "the link")"
        case "press": return "Pressing “\(Controls.latest.value[Controls.id(self)]?.label ?? "it")”"
        case "type_text": return "Typing “\(string("text"))”"
        case "close_tabs":
            let n = (arguments["urls"] as? [String])?.count ?? 0
            return "Closing \(n) tab\(n == 1 ? "" : "s")"
        case "open_app": return "Opening \(string("name"))"
        case "reveal_or_open_file": return "Opening \((string("path") as NSString).lastPathComponent)"
        case "copy_to_clipboard": return "Copying"
        case "create_event": return "Adding to Calendar"
        case "create_reminder": return "Adding the reminder"
        case "move_files": return "Moving files"
        case "run_shortcut": return "Running \(string("name"))"
        case "trim_and_merge_videos": return "Making the video"
        case "insert_text": return "Inserting"
        case "press_shortcut": return "Pressing \(Tools.symbols(string("keys")))"
        case "use_computer": return "Working out what to click"
        default: return name
        }
    }
}

enum Tools {
    static let declarations: [[String: Any]] = {
        func fn(_ name: String, _ desc: String, _ props: [String: Any], _ req: [String]) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": desc,
                                              "parameters": ["type": "object", "properties": props, "required": req]]]
        }
        let s: [String: Any] = ["type": "string"]
        return [
            fn("web_search", "Search the web. Use it for anything current or that you aren't sure of: news, launches and release dates, prices, scores, weather, recent versions, who holds a role now. Returns dated excerpts.",
               ["query": ["type": "string", "description": "A short search query in English, with names spelled out"]], ["query"]),
            fn("open_url", "Open one or more web pages in the browser, one tab each (up to 5). Use exact URLs from PAGE_LINKS, or ones you know.",
               ["urls": ["type": "array", "items": s, "maxItems": 5]], ["urls"]),
            fn("close_tabs", "Close browser tabs by URL, in any window. Use it for \"close them\" or \"close the Instagram tab\": pass the URLs of the tabs (from the history of what you opened, or BROWSER). A URL also matches pages under it. Returns which tabs it actually closed.",
               ["urls": ["type": "array", "items": s]], ["urls"]),
                        fn("open_app", "Open or focus a Mac app by name", ["name": s], ["name"]),
            fn("reveal_or_open_file", "Open a file, or reveal it in Finder", ["path": s, "reveal": ["type": "boolean"]], ["path"]),
            fn("insert_text", "Insert text into the field the user was focused on", ["text": s], ["text"]),
            fn("copy_to_clipboard", "Copy text to the clipboard", ["text": s], ["text"]),
            fn("create_event", "Create a calendar event", ["title": s, "start": ["type": "string", "description": "ISO 8601"],
                                                           "end": ["type": "string", "description": "ISO 8601"], "notes": s], ["title", "start"]),
            fn("create_reminder", "Create a reminder", ["title": s, "due": ["type": "string", "description": "ISO 8601"]], ["title"]),
            fn("move_files", "Move files to a folder, creating it if needed",
               ["paths": ["type": "array", "items": s], "destination": s], ["paths", "destination"]),
            fn("run_shortcut", "Run a Shortcuts shortcut by name", ["name": s, "input": s], ["name"]),
            fn("trim_and_merge_videos", "Trim videos and/or join them one after another into a new .mov (original files untouched). Use FINDER_SELECTION paths. start/end are times within each clip, as seconds or m:ss; omit both to keep the whole clip. \"Keep the first 9:35\" means end 9:35.",
               ["clips": ["type": "array", "items": ["type": "object", "properties": ["path": s, "start": s, "end": s], "required": ["path"]]],
                "output": ["type": "string", "description": "Optional output path; default is next to the first clip"]], ["clips"]),
            fn("press_shortcut", "Press a keyboard shortcut in an app (default: the app the user is in). Use it for anything a shortcut does; common ones are under SHORTCUTS in your instructions.",
               ["keys": ["type": "string", "description": "Keys joined with +, e.g. cmd+w, cmd+shift+t, ctrl+cmd+f"],
                "app": ["type": "string", "description": "App name; omit for the app the user is in"]], ["keys"]),
            fn("press", "Press a button, toggle, tab or menu listed in CONTROLS, by its id. Instant, no screenshot. Use it for clicks like follow, like, mute, play, a setting's switch, a toolbar button.",
               ["id": ["type": "integer", "description": "The id from CONTROLS"]], ["id"]),
            fn("type_text", "Type into a text or search field listed in CONTROLS, by its id, replacing what's there; submit presses Return. Use it to search a site or app on screen (its search field), or fill one field.",
               ["id": ["type": "integer", "description": "The id of a text field from CONTROLS"], "text": s,
                "submit": ["type": "boolean", "description": "Press Return after typing (default true)"]], ["id", "text"]),
            fn("use_computer", "Do something on screen by clicking and typing (an agent that sees the window), only when no other tool fits: the target isn't in CONTROLS or PAGE_LINKS, or it needs typing or several steps. Slow (seconds per step).",
               ["task": ["type": "string", "description": "One clear English instruction naming the exact on-screen target"]], ["task"]),
        ]
    }()

    static let store = EKEventStore()

    /// Shortcuts that can lose work: quit, delete, force quit, log out.
    static func isDestructive(shortcut: String) -> Bool {
        let k = Set(shortcut.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) })
        guard k.contains("cmd") || k.contains("command") else { return false }
        return k.contains("q") || k.contains("delete") || k.contains("backspace") || k.contains("forwarddelete") || k.contains("escape") || k.contains("esc")
    }

    /// "cmd+shift+t" → "⇧⌘T" for status lines and the confirm card.
    static func symbols(_ shortcut: String) -> String {
        let order = ["ctrl": "⌃", "control": "⌃", "alt": "⌥", "option": "⌥", "shift": "⇧", "cmd": "⌘", "command": "⌘"]
        let parts = shortcut.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        let mods = ["⌃", "⌥", "⇧", "⌘"].filter { m in parts.contains { order[$0] == m } }.joined()
        let key = parts.last { order[$0] == nil } ?? ""
        let named = ["[": "[", "]": "]", "plus": "+", "minus": "−", "delete": "⌫", "backspace": "⌫", "space": "Space", "pagedown": "⇟", "esc": "⎋", "escape": "⎋"]
        return mods + (named[key] ?? key.uppercased())
    }

    static func parseDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
                                                    [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]] {
            f.formatOptions = opts
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func humanDate(_ s: String) -> String {
        guard let d = parseDate(s) else { return s }
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }

    /// Runs a tool and returns a short result string for the model.
    static func run(_ call: ToolCall, insertInto pid: pid_t?) async -> String {
        do {
            switch call.name {
            case "web_search":
                return await WebSearch.run(query: call.string("query"))
            case "open_url":
                let urls = call.urlList.compactMap { URL(string: $0) }.filter { $0.scheme != nil }
                guard !urls.isEmpty else { return "error: bad url (pass full https URLs in \"urls\")" }
                await MainActor.run { for u in urls.prefix(5) { _ = NSWorkspace.shared.open(u) } }
                return urls.count == 1 ? "opened" : "opened \(min(urls.count, 5)) tabs"
            case "press":
                return await Controls.press(Controls.id(call), pid: pid)
            case "type_text":
                return await Controls.type(Controls.id(call), text: call.string("text"), submit: call.arguments["submit"] as? Bool ?? true, pid: pid)
            case "close_tabs":
                return await BrowserTabs.close(matching: (call.arguments["urls"] as? [String]) ?? [], frontPid: pid)
            case "open_app":
                let name = call.string("name")
                // Straight through LaunchServices when we know the bundle: no `open` process to spawn.
                if let app = AppIndex.lookup(name) {
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.activates = true
                    await MainActor.run { FocusMove.begin() }
                    if (try? await NSWorkspace.shared.openApplication(at: app.url, configuration: cfg)) != nil { return "opened \(app.name)" }
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-a", name]
                try p.run(); p.waitUntilExit()
                return p.terminationStatus == 0 ? "opened \(name)" : "error: no app named \(name)"
            case "reveal_or_open_file":
                let url = URL(fileURLWithPath: (call.string("path") as NSString).expandingTildeInPath)
                await MainActor.run {
                    if call.arguments["reveal"] as? Bool == true { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    else { NSWorkspace.shared.open(url) }
                }
                return "done"
            case "copy_to_clipboard":
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(call.string("text"), forType: .string)
                }
                return "copied"
            case "insert_text":
                await Inserter.insert(call.string("text"), into: pid)
                return "inserted"
            case "press_shortcut":
                let keys = call.string("keys").split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
                let name = call.string("app")
                let app = name.isEmpty ? pid.flatMap { NSRunningApplication(processIdentifier: $0) }
                    : NSWorkspace.shared.runningApplications.first { ($0.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame }
                guard let app else { return "error: \(name.isEmpty ? "no app to send it to" : "\(name) isn't running")" }
                // Already in front (the usual case: the panel doesn't take activation) → press at once.
                // Otherwise bring it forward and wait only until it actually is, at most 300 ms.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                    await MainActor.run { FocusMove.begin(); app.activate() }
                    for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                let sent = ComputerUser.pressKeys(keys, src: HotkeyMonitor.syntheticSource(.combinedSessionState), toPid: app.processIdentifier)
                return sent ? "pressed \(call.string("keys")) in \(app.localizedName ?? "the app")" : "error: unknown key in \(call.string("keys"))"
            case "create_event":
                try await requestCalendar()
                let ev = EKEvent(eventStore: store)
                ev.title = call.string("title")
                ev.startDate = parseDate(call.string("start")) ?? Date().addingTimeInterval(3600)
                ev.endDate = parseDate(call.string("end")) ?? ev.startDate.addingTimeInterval(1800)
                ev.notes = call.arguments["notes"] as? String
                ev.calendar = store.defaultCalendarForNewEvents
                try store.save(ev, span: .thisEvent)
                return "event created"
            case "create_reminder":
                try await requestReminders()
                let r = EKReminder(eventStore: store)
                r.title = call.string("title")
                r.calendar = store.defaultCalendarForNewReminders()
                if let due = parseDate(call.string("due")) {
                    r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                    r.addAlarm(EKAlarm(absoluteDate: due))
                }
                try store.save(r, commit: true)
                return "reminder created"
            case "move_files":
                let dest = URL(fileURLWithPath: (call.string("destination") as NSString).expandingTildeInPath)
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                var moved = 0
                for p in (call.arguments["paths"] as? [String]) ?? [] {
                    let src = URL(fileURLWithPath: p)
                    try FileManager.default.moveItem(at: src, to: dest.appendingPathComponent(src.lastPathComponent))
                    moved += 1
                }
                return "moved \(moved) files"
            case "trim_and_merge_videos":
                let clips = ((call.arguments["clips"] as? [[String: Any]]) ?? []).map {
                    Media.Clip(url: URL(fileURLWithPath: (($0["path"] as? String ?? "") as NSString).expandingTildeInPath),
                               start: Media.seconds($0["start"]), end: Media.seconds($0["end"]))
                }
                let out = call.string("output").isEmpty ? nil : URL(fileURLWithPath: (call.string("output") as NSString).expandingTildeInPath)
                let r = try await Media.trimAndMerge(clips, output: out)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
                return String(format: "saved %@ (%d:%02d long), revealed in Finder", r.url.path, Int(r.seconds) / 60, Int(r.seconds) % 60)
            case "run_shortcut":
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                p.arguments = ["run", call.string("name")]
                let input = call.string("input")
                if !input.isEmpty {
                    let pipe = Pipe(); p.standardInput = pipe
                    try p.run()
                    pipe.fileHandleForWriting.write(input.data(using: .utf8)!)
                    pipe.fileHandleForWriting.closeFile()
                } else { try p.run() }
                p.waitUntilExit()
                return p.terminationStatus == 0 ? "ran" : "error: shortcut failed"
            default:
                return "error: unknown tool"
            }
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    static func requestCalendar() async throws {
        if #available(macOS 14.0, *) {
            guard try await store.requestFullAccessToEvents() else { throw NSError(domain: "calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar access was denied"]) }
        }
    }

    static func requestReminders() async throws {
        if #available(macOS 14.0, *) {
            guard try await store.requestFullAccessToReminders() else { throw NSError(domain: "reminders", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reminders access was denied"]) }
        }
    }
}

/// Puts text into the previously focused field: activate that app, paste, restore the clipboard.
enum Inserter {
    @MainActor
    static func insert(_ text: String, into pid: pid_t?) async {
        FocusMove.begin()
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        if let pid, let app = NSRunningApplication(processIdentifier: pid) { app.activate() }
        try? await Task.sleep(nanoseconds: 120_000_000)
        let src = HotkeyMonitor.syntheticSource(.combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 400_000_000)
        if let saved { pb.clearContents(); pb.setString(saved, forType: .string) }
    }
}
