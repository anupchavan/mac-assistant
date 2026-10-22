import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// Everything we know about the user's screen at summon time (prompts.md §2).
struct ScreenContext {
    var appName: String = ""
    var bundleID: String = ""
    var pid: pid_t = 0
    var windowTitle: String = ""
    var windowFrame: CGRect = .zero          // global, top-left origin (CG coordinates)
    var underPointer: String = ""
    var focused: String = ""
    var selection: String = ""
    /// The focused element has no selected-text attribute even after manual accessibility (not "nothing selected").
    var selectionUnreadable = false
    var finderSelection: [String] = []
    var browserURL: String = ""
    var browserTitle: String = ""
    /// Every open tab, by window, front window first: "title — url". Read with the URL, so tab
    /// questions ("how many tabs do I have open?") are answered from the browser, not from memory.
    var browserTabs: [[String]] = []
    var visibleText: String = ""
    var ocrText: String = ""
    var screenshot: CGImage?                 // the front window only, our panel excluded
    var captureMs: Double = 0
    var pointer: CGPoint = .zero             // CG coordinates
    var pointerElementFrame: CGRect?
    /// Every link on the open web page with its real URL, footer included (browsers only).
    var links: [PageLink] = []
    /// Buttons, toggles and tabs in the focused window, numbered for the press tool.
    var controls: [Control] = []

    var appIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Short label for the footer: "Finder · 1 file", "Chrome · arxiv.org".
    var label: String {
        if !finderSelection.isEmpty {
            return "\(appName) · \(finderSelection.count) file\(finderSelection.count == 1 ? "" : "s")"
        }
        if let host = URL(string: browserURL)?.host {
            return "\(appName) · \(host.replacingOccurrences(of: "www.", with: ""))"
        }
        return appName
    }

    static func tabLines(_ windows: [[String]]) -> String {
        windows.enumerated().map { i, tabs in
            "window \(i + 1)\(i == 0 ? " (front)" : ""), \(tabs.count) tab\(tabs.count == 1 ? "" : "s"):\n" + tabs.map { "- \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// The per-request block, empty lines omitted (prompts.md §2).
    func block(language: String?, outputMode: String, includeOCR: Bool, includeLinks: Bool = false) -> String {
        var lines: [String] = []
        func add(_ k: String, _ v: String, limit: Int = 2000) {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append("\(k): \(String(t.prefix(limit)))") }
        }
        add("APP", bundleID.isEmpty ? appName : "\(appName) (\(bundleID))")
        add("WINDOW", windowTitle)
        add("UNDER_POINTER", underPointer, limit: 500)
        add("FOCUSED", focused, limit: 500)
        add("SELECTION", selection)
        add("FINDER_SELECTION", finderSelection.joined(separator: "\n"))
        if !browserURL.isEmpty { add("BROWSER", browserTitle.isEmpty ? browserURL : "\(browserURL) — \(browserTitle)") }
        if !browserTabs.isEmpty { add("BROWSER_TABS (every open tab, by window)", Self.tabLines(browserTabs), limit: 3000) }
        add("VISIBLE_TEXT (truncated)", visibleText, limit: 3000)
        if includeOCR { add("SCREEN_TEXT_OCR (truncated)", ocrText, limit: 4000) }
        if includeLinks { add("PAGE_LINKS (text | url, whole page)", PageLink.lines(links, pageURL: browserURL), limit: 6000) }
        if includeLinks { add("CONTROLS (id | kind | label, visible in the window)", Controls.lines(controls), limit: 4000) }
        add("LANGUAGE", language ?? "")
        let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]
        add("NOW", f.string(from: Date()))
        add("TIMEZONE", TimeZone.current.identifier)
        lines.append("OUTPUT_MODE: \(outputMode)")
        return lines.joined(separator: "\n")
    }
}

enum ContextCapture {
    /// Capture the frontmost app. Call before the panel shows; the panel is excluded anyway.
    static func capture(excludingPID ourPID: pid_t = ProcessInfo.processInfo.processIdentifier) async -> ScreenContext {
        let t0 = Date()
        var ctx = ScreenContext()
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ourPID else {
            return ctx
        }
        ctx.appName = app.localizedName ?? ""
        ctx.bundleID = app.bundleIdentifier ?? ""
        ctx.pid = app.processIdentifier
        ctx.pointer = CGEvent(source: nil)?.location ?? .zero

        let pid = ctx.pid, bundleID = ctx.bundleID
        async let shot = screenshot(pid: pid)
        async let scripted = scriptedContext(bundleID: bundleID)
        async let links: [PageLink] = PageLink.browsers.contains(bundleID) ? await PageLink.harvest(pid: pid) : []
        async let controls = Controls.harvest(pid: pid)
        readAX(&ctx)
        if let (img, frame) = await shot { ctx.screenshot = img; if ctx.windowFrame == .zero { ctx.windowFrame = frame } }
        let s = await scripted
        ctx.finderSelection = s.finder
        ctx.browserURL = s.url
        ctx.browserTitle = s.title
        ctx.browserTabs = s.tabs
        ctx.links = await links
        ctx.controls = await controls
        ctx.captureMs = Date().timeIntervalSince(t0) * 1000
        Log.info(String(format: "context %@ %.0f ms (shot %@, %d links, %d controls)", ctx.appName, ctx.captureMs, ctx.screenshot == nil ? "no" : "yes", ctx.links.count, ctx.controls.count))
        return ctx
    }

    // MARK: Accessibility

    static func readAX(_ ctx: inout ScreenContext) {
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(ctx.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if let win: AXUIElement = attr(app, kAXFocusedWindowAttribute) {
            AXUIElementSetMessagingTimeout(win, 0.1)
            ctx.windowTitle = attr(win, kAXTitleAttribute) ?? ""
            ctx.windowFrame = frame(of: win) ?? .zero
            var budget = 4000
            var out: [String] = []
            let deadline = Date().addingTimeInterval(0.08)
            collectText(win, depth: 0, budget: &budget, out: &out, deadline: deadline)
            ctx.visibleText = out.joined(separator: "\n")
        }
        func readFocused() -> String? {
            guard let focused: AXUIElement = attr(app, kAXFocusedUIElementAttribute) else { return nil }
            AXUIElementSetMessagingTimeout(focused, 0.1)
            let role: String = attr(focused, kAXRoleAttribute) ?? ""
            let value: String = (attr(focused, kAXValueAttribute) as String?) ?? ""
            ctx.focused = "\(role) \"\(value.prefix(500))\""
            if let s: String = attr(focused, kAXSelectedTextAttribute) { return s }
            return Selection.viaTextMarkers(focused)
        }
        var selection = readFocused()
        // Chrome/Electron expose the selection only once their tree is switched on; give it a moment to build.
        if selection == nil, Selection.enableManualAccessibility(pid: ctx.pid) {
            usleep(60_000)
            selection = readFocused()
        }
        ctx.selection = selection ?? ""
        ctx.selectionUnreadable = selection == nil
        if let el = element(at: ctx.pointer, pid: ctx.pid) {
            AXUIElementSetMessagingTimeout(el, 0.1)
            let role: String = attr(el, kAXRoleAttribute) ?? ""
            let title: String = attr(el, kAXTitleAttribute) ?? attr(el, kAXDescriptionAttribute) ?? ""
            let value: String = (attr(el, kAXValueAttribute) as String?) ?? ""
            ctx.underPointer = [role, title.isEmpty ? "" : "\"\(title)\"", String(value.prefix(300))]
                .filter { !$0.isEmpty }.joined(separator: " ")
            ctx.pointerElementFrame = frame(of: el)
        }
    }

    /// The element of `pid` at a screen point. Never hit-test system-wide: when the point is over one of our
    /// own windows, AppKit answers in-process on this background thread and deadlocks against the main thread.
    static func element(at p: CGPoint, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &el) == .success else { return nil }
        return el
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    static func frame(of el: AXUIElement) -> CGRect? {
        var posV: CFTypeRef?, sizeV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success,
              let posV, let sizeV else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func collectText(_ el: AXUIElement, depth: Int, budget: inout Int, out: inout [String], deadline: Date) {
        guard depth < 12, budget > 0, Date() < deadline else { return }
        // Children otherwise inherit the 6 s global timeout; one stuck element would blow the budget.
        AXUIElementSetMessagingTimeout(el, 0.05)
        let role: String = attr(el, kAXRoleAttribute) ?? ""
        if role == "AXStaticText" || role == "AXHeading" || role == "AXLink" || role == "AXButton" {
            let s: String = (attr(el, kAXValueAttribute) as String?) ?? attr(el, kAXTitleAttribute) ?? attr(el, kAXDescriptionAttribute) ?? ""
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t); budget -= t.count }
        }
        guard let kids: [AXUIElement] = attr(el, kAXVisibleChildrenAttribute) ?? attr(el, kAXChildrenAttribute) else { return }
        for k in kids.prefix(200) { collectText(k, depth: depth + 1, budget: &budget, out: &out, deadline: deadline) }
    }

    // MARK: Screenshot (ScreenCaptureKit, front window of the pid)

    static func screenshot(pid: pid_t, maxSide: CGFloat = 1440) async -> (CGImage, CGRect)? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        // Front-most on-screen window of that app, from the CG window list (front to back order).
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let entry = list.first {
            guard ($0[kCGWindowOwnerPID as String] as? pid_t) == pid, ($0[kCGWindowLayer as String] as? Int) == 0,
                  let b = $0[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (b["Width"] ?? 0) >= 100 && (b["Height"] ?? 0) >= 100
        }
        guard let windowID = entry?[kCGWindowNumber as String] as? CGWindowID else { return nil }
        do {
            let content = try await shareableContent(containing: windowID)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            var w = window.frame.width * scale, h = window.frame.height * scale
            let k = min(1, maxSide / max(w, h))
            w *= k; h *= k
            config.width = Int(w); config.height = Int(h)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (img, window.frame)
        } catch {
            Log.error("screenshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// SCShareableContent costs ~40 ms; reuse it for a few seconds unless it doesn't know the window.
    private static let shareableCache = Locked<(content: SCShareableContent, at: Date)?>(nil)

    private static func shareableContent(containing windowID: CGWindowID) async throws -> SCShareableContent {
        if let c = shareableCache.value, Date().timeIntervalSince(c.at) < 5,
           c.content.windows.contains(where: { $0.windowID == windowID }) { return c.content }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        shareableCache.value = (content, Date())
        return content
    }

    /// The first ScreenCaptureKit capture in a process costs ~100 ms extra; pay it at launch.
    static func warmUp() async {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let display = content.displays.first else { return }
        shareableCache.value = (content, Date())
        let config = SCStreamConfiguration()
        config.width = 16; config.height = 16
        _ = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
    }

    // MARK: Finder selection / browser URL (Apple Events)

    struct Scripted { var finder: [String] = []; var url = ""; var title = ""; var tabs: [[String]] = [] }

    /// Browser script output: URL, title, then "TAB<tab>window<tab>url<tab>title" lines (front window is 1).
    static func parseBrowser(_ result: String) -> Scripted {
        var s = Scripted()
        var head: [String] = []
        var windows: [Int: [String]] = [:]
        for line in result.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            if f.first == "TAB", f.count >= 3, let w = Int(f[1]) {
                let title = f.count > 3 ? f[3].trimmingCharacters(in: .whitespaces) : ""
                windows[w, default: []].append(title.isEmpty ? f[2] : "\(title) — \(f[2])")
            } else {
                head.append(line)
            }
        }
        s.url = head.first ?? ""
        s.title = head.dropFirst().first ?? ""
        s.tabs = windows.keys.sorted().compactMap { windows[$0] }
        return s
    }

    private static let scriptQueue = DispatchQueue(label: "applescript")
    private static var compiled: [String: NSAppleScript] = [:]     // scriptQueue only
    private static let scriptBusy = Locked(false)

    /// Returns empty if the script isn't back within `timeout` (first-run consent, a busy app);
    /// a late result is dropped. NSAppleScript can't be cancelled, so a stuck one makes later calls skip.
    static func scriptedContext(bundleID: String, timeout: TimeInterval = 0.15) async -> Scripted {
        let source: String?
        switch bundleID {
        case "com.apple.finder":
            source = """
            tell application "Finder"
              set out to ""
              repeat with i in (get selection)
                set out to out & POSIX path of (i as alias) & linefeed
              end repeat
              return out
            end tell
            """
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi":
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? "Google Chrome"
            source = """
            tell application "\(name)"
              set out to (URL of active tab of front window) & linefeed & (title of active tab of front window)
              set w to 0
              repeat with win in windows
                set w to w + 1
                try
                  set us to URL of every tab of win
                  set ns to title of every tab of win
                  repeat with i from 1 to count of us
                    set u to item i of us
                    if u is missing value then set u to "(blank tab)"
                    set n to item i of ns
                    if n is missing value then set n to ""
                    set out to out & linefeed & "TAB" & (character id 9) & w & (character id 9) & u & (character id 9) & n
                  end repeat
                end try
              end repeat
              return out
            end tell
            """
        case "com.apple.Safari":
            source = """
            tell application "Safari"
              set out to (URL of front document) & linefeed & (name of front document)
              set w to 0
              repeat with win in windows
                set w to w + 1
                try
                  set us to URL of every tab of win
                  set ns to name of every tab of win
                  repeat with i from 1 to count of us
                    set u to item i of us
                    if u is missing value then set u to "(blank tab)"
                    set n to item i of ns
                    if n is missing value then set n to ""
                    set out to out & linefeed & "TAB" & (character id 9) & w & (character id 9) & u & (character id 9) & n
                  end repeat
                end try
              end repeat
              return out
            end tell
            """
        default:
            source = nil
        }
        guard let source else { return Scripted() }
        guard scriptBusy.swap(true) == false else { Log.info("applescript still busy; skipped"); return Scripted() }
        let resumed = Locked(false)
        return await withCheckedContinuation { cont in
            scriptQueue.async {
                var err: NSDictionary?
                if compiled[source] == nil, let script = NSAppleScript(source: source), script.compileAndReturnError(&err) {
                    compiled[source] = script
                }
                let result = compiled[source]?.executeAndReturnError(&err).stringValue ?? ""
                scriptBusy.value = false
                var s = Scripted()
                let parts = result.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                if bundleID == "com.apple.finder" { s.finder = parts }
                else { s = parseBrowser(result) }
                if resumed.swap(true) == false { cont.resume(returning: s) } else { Log.info("applescript late; dropped") }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if resumed.swap(true) == false { cont.resume(returning: Scripted()) }
            }
        }
    }

    // MARK: OCR (fallback when the vision model isn't available)

    static func ocr(_ image: CGImage) async -> String {
        await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            req.recognitionLevel = .fast
            req.usesLanguageCorrection = false
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: image).perform([req]) }
                catch { cont.resume(returning: "") }
            }
        }
    }

    // MARK: Encoding

    static func jpegDataURL(_ img: CGImage, maxSide: CGFloat = 1280, quality: CGFloat = 0.7) -> String? {
        encode(img, maxSide: maxSide, type: .jpeg, props: [.compressionFactor: quality]).map { "data:image/jpeg;base64," + $0.base64EncodedString() }
    }

    static func pngDataURL(_ img: CGImage) -> String? {
        encode(img, maxSide: 1440, type: .png, props: [:]).map { "data:image/png;base64," + $0.base64EncodedString() }
    }

    static func encode(_ img: CGImage, maxSide: CGFloat, type: NSBitmapImageRep.FileType, props: [NSBitmapImageRep.PropertyKey: Any]) -> Data? {
        var image = img
        let k = maxSide / CGFloat(max(img.width, img.height))
        if k < 1 {
            let w = Int(CGFloat(img.width) * k), h = Int(CGFloat(img.height) * k)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { image = scaled }
            }
        }
        return NSBitmapImageRep(cgImage: image).representation(using: type, properties: props)
    }
}

/// A value behind a lock, for the few bits of state shared across capture tasks.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
    /// Sets the new value and returns the old one, atomically.
    func swap(_ new: T) -> T { lock.lock(); defer { lock.unlock() }; let old = v; v = new; return old }
}
