import AppKit
import ApplicationServices

/// A link on the open web page. Read through accessibility, so links scrolled out of view (social icons in
/// the footer) come with their real URL, and "open their Instagram" is one open_url call, not a vision loop.
struct PageLink: Equatable {
    var text: String
    var url: String

    static let browsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
                                        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
                                        "com.vivaldi.Vivaldi", "com.google.Chrome.canary"]

    /// The page's links in document order. WebKit and Chromium both answer VoiceOver's link search in one
    /// call; then one batched attribute read per link. Gives up quietly at the deadline.
    static func harvest(pid: pid_t, deadline seconds: TimeInterval = 0.25, limit: Int = 400) async -> [PageLink] {
        await Task.detached(priority: .userInitiated) { () -> [PageLink] in
            guard AXIsProcessTrusted() else { return [] }
            let t0 = Date()
            let deadline = t0.addingTimeInterval(seconds)
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            guard let win: AXUIElement = ContextCapture.attr(app, kAXFocusedWindowAttribute),
                  let web = findWebArea(win, deadline: deadline) else { return [] }
            AXUIElementSetMessagingTimeout(web, 0.15)
            let predicate: [String: Any] = ["AXSearchKey": "AXLinkSearchKey", "AXResultsLimit": limit,
                                            "AXDirection": "AXDirectionNext", "AXVisibleOnly": false,
                                            "AXImmediateDescendantsOnly": false]
            var found: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(web, "AXUIElementsForSearchPredicate" as CFString,
                                                            predicate as CFDictionary, &found) == .success,
                  let elements = found as? [AXUIElement] else { return [] }
            var out: [PageLink] = []
            let names = [kAXURLAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] as CFArray
            for el in elements where Date() < deadline {
                AXUIElementSetMessagingTimeout(el, 0.05)
                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(el, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                      let v = values as? [Any], v.count == 4 else { continue }
                let url = (v[0] as? URL)?.absoluteString ?? (v[0] as? String) ?? ""
                guard !url.isEmpty else { continue }
                let text = [v[1], v[2], v[3]].compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
                out.append(PageLink(text: text, url: url))
            }
            Log.info(String(format: "page links %d of %d in %.0f ms", out.count, elements.count, Date().timeIntervalSince(t0) * 1000))
            return out
        }.value
    }

    /// Breadth-first: the web area sits a few levels under the window (split group, tab group, scroll area).
    private static func findWebArea(_ root: AXUIElement, deadline: Date) -> AXUIElement? {
        var queue = [root]
        var seen = 0
        while !queue.isEmpty, seen < 300, Date() < deadline {
            let el = queue.removeFirst()
            seen += 1
            AXUIElementSetMessagingTimeout(el, 0.05)
            if (ContextCapture.attr(el, kAXRoleAttribute) as String?) == "AXWebArea" { return el }
            if let kids: [AXUIElement] = ContextCapture.attr(el, kAXChildrenAttribute) { queue += kids.prefix(40) }
        }
        return nil
    }

    /// The PAGE_LINKS block: web links only, one per URL, other sites first (profiles, stores, docs), then
    /// this site's own pages (a third of the room is kept for them), at most `max` lines so the prompt stays small.
    static func lines(_ links: [PageLink], pageURL: String, max: Int = 80) -> String {
        let pageHost = host(pageURL)
        var seen = Set<String>()
        var external: [String] = [], internal: [String] = []
        for l in links {
            guard let u = URL(string: l.url), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let h = u.host?.lowercased() else { continue }
            var key = l.url
            if let hash = key.firstIndex(of: "#") { key = String(key[..<hash]) }
            if key.hasSuffix("/") { key.removeLast() }
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let text = String(l.text.replacingOccurrences(of: "\n", with: " ").prefix(60))
            let line = "\(text.isEmpty ? "-" : text) | \(String(l.url.prefix(160)))"
            if pageHost.isEmpty || Self.host(h) != pageHost { external.append(line) } else { internal.append(line) }
        }
        let ext = external.prefix(max - min(internal.count, max / 3))
        return (ext + internal.prefix(max - ext.count)).joined(separator: "\n")
    }

    static func host(_ s: String) -> String {
        let h = (URL(string: s)?.host ?? s).lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}
