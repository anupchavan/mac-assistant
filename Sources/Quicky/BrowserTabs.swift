import AppKit

/// Closes browser tabs by URL through Apple Events, so "close them" closes exactly the tabs Quicky opened,
/// wherever they are, instead of pressing cmd+w on whatever happens to be in front.
enum BrowserTabs {
    private static let queue = DispatchQueue(label: "browser-tabs")
    private static let chromium: Set<String> = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
                                                "company.thebrowser.Browser", "com.vivaldi.Vivaldi"]

    struct Tab { var window: Int; var index: Int; var url: String; var title: String }

    /// Every tab of every window, front window first (window 1). Two Apple Events per window, not one per tab.
    static func read(_ name: String) async -> [Tab]? {
        let titleKey = name == "Safari" ? "name" : "title"
        let source = """
        tell application "\(name)"
          set out to ""
          set w to 0
          repeat with win in windows
            set w to w + 1
            try
              set us to URL of every tab of win
              set ns to \(titleKey) of every tab of win
              repeat with i from 1 to count of us
                set u to item i of us
                if u is missing value then set u to ""
                set n to item i of ns
                if n is missing value then set n to ""
                set out to out & w & (character id 9) & i & (character id 9) & u & (character id 9) & n & linefeed
              end repeat
            end try
          end repeat
          return out
        end tell
        """
        guard let out = await run(source) else { return nil }
        return parse(out)
    }

    static func parse(_ out: String) -> [Tab] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, let w = Int(f[0]), let t = Int(f[1]) else { return nil }
            return Tab(window: w, index: t, url: f[2], title: f.count > 3 ? f[3] : "")
        }
    }

    /// For the list_tabs tool: what's open, by window, so tab questions are answered from the browser, not memory.
    static func list(frontPid: pid_t?, filter: String = "") async -> String {
        guard let app = browser(frontPid: frontPid) else { return "no supported browser is running" }
        let name = app.localizedName ?? "Safari"
        guard let tabs = await read(name) else { return "error: couldn't read \(name)'s tabs (allow Automation for Quicky in System Settings)" }
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return describe(tabs, browser: name) }
        let hits = tabs.filter { $0.url.lowercased().contains(f) || $0.title.lowercased().contains(f) }
        return "\(tabs.count) tabs open in all; matching “\(filter)”: " + (hits.isEmpty ? "none" : "\n" + describe(hits, browser: name))
    }

    static func describe(_ tabs: [Tab], browser name: String) -> String {
        guard !tabs.isEmpty else { return "\(name) has no open windows" }
        let windows = Dictionary(grouping: tabs, by: \.window).sorted { $0.key < $1.key }
        let head = "\(name): \(tabs.count) tab\(tabs.count == 1 ? "" : "s") in \(windows.count) window\(windows.count == 1 ? "" : "s")"
        return ([head] + windows.map { w, ts in
            "window \(w)\(w == 1 ? " (front)" : ""), \(ts.count) tab\(ts.count == 1 ? "" : "s"):\n" + ts.map { t in
                let u = t.url.isEmpty ? "(blank tab)" : t.url
                return "- " + (t.title.isEmpty ? u : "\(t.title) — \(u)")
            }.joined(separator: "\n")
        }).joined(separator: "\n")
    }

    static func close(matching urls: [String], frontPid: pid_t?) async -> String {
        let wanted = urls.map(key).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return "error: no URLs given" }
        guard let app = browser(frontPid: frontPid) else { return "error: no supported browser is running" }
        let name = app.localizedName ?? "Safari"
        guard let tabs = await read(name) else { return "error: couldn't read \(name)'s tabs (allow Automation for Quicky in System Settings)" }
        let hits = tabs.filter { matches($0.url, wanted) }.map { (w: $0.window, t: $0.index, url: $0.url) }
        guard !hits.isEmpty else { return "no open tab matched; nothing closed" }
        // Highest tab index first, so earlier indices stay valid while closing.
        let closes = hits.sorted { ($0.w, $0.t) > ($1.w, $1.t) }
            .map { "close tab \($0.t) of window \($0.w)" }.joined(separator: "\n  ")
        guard await run("tell application \"\(name)\"\n  \(closes)\nend tell") != nil else { return "error: \(name) refused to close the tabs" }
        return "closed \(hits.count) tab\(hits.count == 1 ? "" : "s") in \(name): " + hits.map(\.url).joined(separator: " ")
    }

    /// The front app when it's a browser, else a running one (Safari first).
    private static func browser(frontPid: pid_t?) -> NSRunningApplication? {
        if let pid = frontPid, let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier,
           id.hasPrefix("com.apple.Safari") || chromium.contains(id) { return app }
        for id in ["com.apple.Safari"] + chromium.sorted() {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return app }
        }
        return nil
    }

    /// host + path, without scheme, "www.", query, fragment or trailing slash: "instagram.com/porter_in".
    static func key(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let r = t.range(of: "://") { t = String(t[r.upperBound...]) }
        if t.hasPrefix("www.") { t = String(t.dropFirst(4)) }
        if let i = t.firstIndex(where: { $0 == "?" || $0 == "#" }) { t = String(t[..<i]) }
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// A tab matches a wanted URL when it is that page or a page under it.
    static func matches(_ tabURL: String, _ wanted: [String]) -> Bool {
        let k = key(tabURL)
        return wanted.contains { k == $0 || k.hasPrefix($0 + "/") }
    }

    private static func run(_ source: String) async -> String? {
        await withCheckedContinuation { cont in
            queue.async {
                var err: NSDictionary?
                let out = NSAppleScript(source: source)?.executeAndReturnError(&err)
                if let err { Log.error("browser tabs applescript: \(err[NSAppleScript.errorMessage] ?? err)") }
                cont.resume(returning: err == nil ? (out?.stringValue ?? "") : nil)
            }
        }
    }
}
