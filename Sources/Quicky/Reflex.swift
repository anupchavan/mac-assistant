import AppKit

/// Asks so common and so unambiguous that the model adds nothing but latency: "close this tab", "new tab",
/// "go back", "open Notes", "open youtube". They become tool calls in code, in well under a millisecond,
/// with a short spoken reply, and the model is never called. Only whole utterances match; anything longer
/// or less certain ("close the tab and tell me…", "open their Instagram") goes to the model as before.
struct Reflex {
    let calls: [ToolCall]
    let reply: String
    let label: String

    // MARK: Shortcuts

    private struct Rule { let pattern: String; let keys: String; let reply: String; let hinglish: Bool }

    /// Anchored, after `normalize` (lowercase, punctuation and filler removed).
    private static let rules: [Rule] = [
        Rule(pattern: #"close( (this|the|that|current))?( (tab|window|one|page))?|close it"#, keys: "cmd+w", reply: "Closed.", hinglish: false),
        Rule(pattern: #"(open )?(a )?new tab"#, keys: "cmd+t", reply: "New tab.", hinglish: false),
        Rule(pattern: #"(open )?(a )?new window"#, keys: "cmd+n", reply: "New window.", hinglish: false),
        Rule(pattern: #"(reopen|undo close)( the)?( last)?( closed)?( tab)?|(restore|bring back)( the)?( last)?( closed)? tab"#, keys: "cmd+shift+t", reply: "Brought it back.", hinglish: false),
        Rule(pattern: #"(reload|refresh)( (this|the|that))?( (page|tab|site))?"#, keys: "cmd+r", reply: "Reloaded.", hinglish: false),
        Rule(pattern: #"(go )?back"#, keys: "cmd+[", reply: "Back.", hinglish: false),
        Rule(pattern: #"(go )?forward"#, keys: "cmd+]", reply: "Forward.", hinglish: false),
        Rule(pattern: #"(go to )?(the )?next tab"#, keys: "ctrl+tab", reply: "Next tab.", hinglish: false),
        Rule(pattern: #"(go to )?(the )?(previous|last) tab"#, keys: "ctrl+shift+tab", reply: "Previous tab.", hinglish: false),
        Rule(pattern: #"zoom in"#, keys: "cmd+plus", reply: "Zoomed in.", hinglish: false),
        Rule(pattern: #"zoom out"#, keys: "cmd+minus", reply: "Zoomed out.", hinglish: false),
        Rule(pattern: #"(reset zoom|actual size)"#, keys: "cmd+0", reply: "Back to normal size.", hinglish: false),
        Rule(pattern: #"((go|make (it|this)) )?full ?screen"#, keys: "ctrl+cmd+f", reply: "Full screen.", hinglish: false),
        Rule(pattern: #"minimi[sz]e( (this|it|the window))?"#, keys: "cmd+m", reply: "Minimized.", hinglish: false),
        Rule(pattern: #"undo( that| it)?"#, keys: "cmd+z", reply: "Undone.", hinglish: false),
        Rule(pattern: #"redo( that| it)?"#, keys: "cmd+shift+z", reply: "Redone.", hinglish: false),
        Rule(pattern: #"select all"#, keys: "cmd+a", reply: "Selected all.", hinglish: false),
        Rule(pattern: #"scroll down"#, keys: "pagedown", reply: "Scrolled.", hinglish: false),
        Rule(pattern: #"scroll up"#, keys: "pageup", reply: "Scrolled.", hinglish: false),
        Rule(pattern: #"((isko|ise|ye|yeh|is tab ko|tab) )?(band|bandh) kar( ?(do|o|de))?"#, keys: "cmd+w", reply: "Band kar diya.", hinglish: true),
        Rule(pattern: #"naya tab( kholo| khol do)?"#, keys: "cmd+t", reply: "Naya tab.", hinglish: true),
        Rule(pattern: #"(peeche|piche|wapas|vapas) (jao|chalo)"#, keys: "cmd+[", reply: "Peeche.", hinglish: true),
        Rule(pattern: #"aage (jao|chalo)"#, keys: "cmd+]", reply: "Aage.", hinglish: true),
        Rule(pattern: #"(refresh|reload) kar( ?(do|o))?"#, keys: "cmd+r", reply: "Refresh kar diya.", hinglish: true),
    ]

    /// The spoken reply for a shortcut the model chose ("cmd+w" → "Closed.").
    static func reply(forKeys keys: String) -> String? {
        let k = keys.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "command", with: "cmd")
            .replacingOccurrences(of: "control", with: "ctrl")
        return rules.first { !$0.hinglish && $0.keys == k }?.reply
    }

    /// Well-known sites for "open youtube" when no installed app has that name.
    static let sites: [String: (url: String, name: String)] = [
        "youtube": ("https://www.youtube.com", "YouTube"), "gmail": ("https://mail.google.com", "Gmail"),
        "google": ("https://www.google.com", "Google"), "github": ("https://github.com", "GitHub"),
        "twitter": ("https://x.com", "X"), "x": ("https://x.com", "X"), "linkedin": ("https://www.linkedin.com", "LinkedIn"),
        "instagram": ("https://www.instagram.com", "Instagram"), "reddit": ("https://www.reddit.com", "Reddit"),
        "chatgpt": ("https://chatgpt.com", "ChatGPT"), "claude": ("https://claude.ai", "Claude"),
        "google drive": ("https://drive.google.com", "Google Drive"), "drive": ("https://drive.google.com", "Google Drive"),
        "google calendar": ("https://calendar.google.com", "Google Calendar"), "google docs": ("https://docs.google.com", "Google Docs"),
        "netflix": ("https://www.netflix.com", "Netflix"), "amazon": ("https://www.amazon.in", "Amazon"),
        "hacker news": ("https://news.ycombinator.com", "Hacker News"), "wikipedia": ("https://www.wikipedia.org", "Wikipedia"),
        "figma": ("https://www.figma.com", "Figma"), "sarvam dashboard": ("https://dashboard.sarvam.ai", "the Sarvam dashboard"),
    ]

    /// Lowercase, no punctuation, no "hey quicky / can you / please / for me".
    static func normalize(_ ask: String) -> String {
        var t = ask.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s.\-]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\.(\s|$)"#, with: " ", options: .regularExpression)   // sentence dots, not "x.com"
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let lead = #"^((hey|ok|okay|yo|hi) )?(quicky |quickie )?((can|could|will|would) you |please |pls |just |kindly )*"#
        let tail = #"( (please|pls|for me|now|quickly|right now|yaar|na))+$"#
        for _ in 0..<2 {
            t = t.replacingOccurrences(of: lead, with: "", options: .regularExpression)
                 .replacingOccurrences(of: tail, with: "", options: .regularExpression)
                 .trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// `links` are the open page's links: when one of them points at the named site ("open instagram" on a
    /// creator's page), the user may mean that profile, so the model decides.
    static func match(_ ask: String, links: [PageLink] = []) -> Reflex? {
        let t = normalize(ask)
        guard !t.isEmpty, t.split(separator: " ").count <= 6 else { return nil }

        for r in rules where t.range(of: "^(\(r.pattern))$", options: .regularExpression) != nil {
            // No app name: Tools.run sends it to the front app's pid, which is exactly the app they were in.
            let call = ToolCall(id: "reflex", name: "press_shortcut", arguments: ["keys": r.keys], rawArguments: "")
            return Reflex(calls: [call], reply: r.reply, label: "shortcut \(r.keys)")
        }

        // "open notes", "launch the figma app", "youtube kholo"
        var target: String?
        if let m = t.range(of: #"^(open|launch|start|go to|switch to|show) (up )?"#, options: .regularExpression) { target = String(t[m.upperBound...]) }
        else if let m = t.range(of: #" (kholo|khol do|chalao|open karo|open kar do)$"#, options: .regularExpression) { target = String(t[..<m.lowerBound]) }
        guard var name = target?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        name = name.replacingOccurrences(of: #"^(the|my) "#, with: "", options: .regularExpression)
                   .replacingOccurrences(of: #" (app|application|website|site|web ?site)$"#, with: "", options: .regularExpression)
        guard !name.isEmpty, !name.contains(" and "), name.split(separator: " ").count <= 3 else { return nil }
        // Words that point at the screen or at someone ("open this", "open their instagram") need the model.
        if name.range(of: #"\b(this|that|it|these|those|their|his|her|its|link|file|folder|tab|page|first|second|last|next)\b"#, options: .regularExpression) != nil { return nil }

        if name.range(of: #"^[a-z0-9\-]+(\.[a-z0-9\-]+)+(/\S*)?$"#, options: .regularExpression) != nil {
            let url = "https://" + name
            return Reflex(calls: [ToolCall(id: "reflex", name: "open_url", arguments: ["url": url], rawArguments: "")],
                          reply: "Opening \(name).", label: "url \(name)")
        }
        if let app = AppIndex.lookup(name) {
            return Reflex(calls: [ToolCall(id: "reflex", name: "open_app", arguments: ["name": app.name], rawArguments: "")],
                          reply: "Opening \(app.name).", label: "app \(app.name)")
        }
        if let site = sites[name] {
            let host = PageLink.host(site.url)
            if links.contains(where: { PageLink.host($0.url) == host }) { return nil }
            return Reflex(calls: [ToolCall(id: "reflex", name: "open_url", arguments: ["url": site.url], rawArguments: "")],
                          reply: "Opening \(site.name).", label: "site \(site.name)")
        }
        return nil
    }
}

/// Installed apps by lowercase name, read once in the background at launch (a few ms), so "open Notes"
/// resolves without spawning `open -a`.
enum AppIndex {
    struct App { let name: String; let url: URL }
    private static let lock = NSLock()
    private static var byName: [String: App] = [:]

    static let aliases: [String: String] = [
        "chrome": "google chrome", "vs code": "visual studio code", "vscode": "visual studio code", "code": "visual studio code",
        "settings": "system settings", "system preferences": "system settings", "app store": "app store",
        "teams": "microsoft teams", "word": "microsoft word", "excel": "microsoft excel", "powerpoint": "microsoft powerpoint",
        "outlook": "microsoft outlook", "whatsapp": "whatsapp", "music": "music", "terminal": "terminal", "iterm": "iterm",
    ]

    static func load() {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        var found: [String: App] = [:]
        for root in roots {
            for item in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                let key = name.lowercased()
                if found[key] == nil { found[key] = App(name: name, url: URL(fileURLWithPath: root).appendingPathComponent(item)) }
            }
        }
        lock.lock(); byName = found; lock.unlock()
        Log.info("app index: \(found.count) apps")
    }

    static func lookup(_ spoken: String) -> App? {
        let k = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        lock.lock(); defer { lock.unlock() }
        if let a = byName[k] { return a }
        if let alias = aliases[k], let a = byName[alias] { return a }
        // "notes" → "Notes", "photoshop" → "Adobe Photoshop 2026"
        let candidates = byName.filter { $0.key.hasPrefix("adobe \(k)") || $0.key == "microsoft \(k)" || $0.key == "google \(k)" }
        return candidates.count == 1 ? candidates.first?.value : nil
    }
}
