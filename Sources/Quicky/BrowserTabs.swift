import AppKit

/// Closes browser tabs by URL through Apple Events, so "close them" closes exactly the tabs Quicky opened,
/// wherever they are, instead of pressing cmd+w on whatever happens to be in front.
enum BrowserTabs {
    private static let queue = DispatchQueue(label: "browser-tabs")
    private static let chromium: Set<String> = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
                                                "company.thebrowser.Browser", "com.vivaldi.Vivaldi"]

    static func close(matching urls: [String], frontPid: pid_t?) async -> String {
        let wanted = urls.map(key).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return "error: no URLs given" }
        guard let app = browser(frontPid: frontPid) else { return "error: no supported browser is running" }
        let name = app.localizedName ?? "Safari"
        // Window index, tab index and URL of every tab.
        let list = """
        tell application "\(name)"
          set out to ""
          repeat with w from 1 to count of windows
            repeat with t from 1 to count of tabs of window w
              set out to out & w & (character id 9) & t & (character id 9) & (URL of tab t of window w) & linefeed
            end repeat
          end repeat
          return out
        end tell
        """
        guard let tabs = await run(list) else { return "error: couldn't read \(name)'s tabs (allow Automation for Quicky in System Settings)" }
        var hits: [(w: Int, t: Int, url: String)] = []
        for line in tabs.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3, let w = Int(f[0]), let t = Int(f[1]) else { continue }
            if matches(f[2], wanted) { hits.append((w, t, f[2])) }
        }
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
                if let err { Log.error("close_tabs applescript: \(err[NSAppleScript.errorMessage] ?? err)") }
                cont.resume(returning: err == nil ? (out?.stringValue ?? "") : nil)
            }
        }
    }
}
