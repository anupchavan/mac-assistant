import AppKit
import ApplicationServices
import QuickyCore
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private let engine: Engine
    private let panel: PanelWindow
    private let hotkey: Hotkey
    private let settings = SettingsWindow()
    private let noticeLog = NoticeLog(url: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Quicky/quicky.log"))
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var grants = Grants.current()

    override init() {
        if let fonts = Bundle.main.resourceURL?.appending(path: "Fonts") { Fonts.register(from: fonts) }
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/dev.anup.assistant")
        engine = Engine(device: MacDevice(), config: Config.load(), storeDirectory: store)
        panel = PanelWindow(engine: engine)
        hotkey = Hotkey(engine: engine, panel: panel)
        super.init()
        engine.onNotice = { [noticeLog] in noticeLog.append($0) }
        panel.openSettings = { [settings] in settings.show() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.editMenu()
        statusItem.button?.image = Self.menuBarImage()
        rebuildMenu()
        grants.requestMissing()
        hotkey.start()
        panel.observe()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.pollGrants()
            }
        }
    }

    private func pollGrants() {
        let now = Grants.current()
        guard now != grants else { return }
        grants = now
        hotkey.start()
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(item("Ask", #selector(ask)))
        menu.addItem(.separator())
        menu.addItem(item("\(grants.accessibility ? "✓" : "✗") Accessibility", #selector(openPrivacyPane(_:)),
                          represented: "Privacy_Accessibility"))
        menu.addItem(item("\(grants.inputMonitoring ? "✓" : "✗") Input Monitoring", #selector(openPrivacyPane(_:)),
                          represented: "Privacy_ListenEvent"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Quit", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", represented: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = represented
        return item
    }

    /// The same raw keys fn+Space produces, so the core treats it exactly like the gesture.
    @objc private func ask() {
        engine.send(.key(.fnDown(shift: false)))
        engine.send(.key(.keyDown(code: 49)))
        engine.send(.key(.fnUp))
    }

    @objc private func openPrivacyPane(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? String,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showSettings() { settings.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// An accessory app has no menu bar of its own, but text fields only get ⌘V, ⌘C and ⌘A through
    /// main-menu key equivalents.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        return main
    }

    private static func menuBarImage() -> NSImage? {
        let renderer = ImageRenderer(content: GlyphView(glyph: .question, size: 18, color: .black))
        renderer.scale = 2
        let image = renderer.nsImage
        image?.isTemplate = true
        return image
    }
}

private struct Grants: Equatable {
    var accessibility: Bool
    var inputMonitoring: Bool

    static func current() -> Grants {
        Grants(accessibility: AXIsProcessTrusted(), inputMonitoring: CGPreflightListenEventAccess())
    }

    func requestMissing() {
        if !accessibility { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
        if !inputMonitoring { CGRequestListenEventAccess() }
    }
}

/// Appends each notice as one JSON line. Writes happen off the main actor, in order.
// The core will own the line codec (`JSONL.swift`); delete `encode` when it lands.
final class NoticeLog: Sendable {
    private let lines: AsyncStream<String>.Continuation

    init(url: URL) {
        let (stream, lines) = AsyncStream<String>.makeStream()
        self.lines = lines
        Task.detached(priority: .utility) {
            let files = FileManager.default
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !files.fileExists(atPath: url.path) { files.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            _ = try? handle.seekToEnd()
            for await line in stream { try? handle.write(contentsOf: Data((line + "\n").utf8)) }
        }
    }

    func append(_ notice: Notice) { lines.yield(Self.encode(notice)) }

    static func encode(_ notice: Notice) -> String {
        var parts = ["\"type\":\(json(notice.type))"]
        if let run = notice.run { parts.append("\"run\":\(json(run))") }
        for (key, value) in notice.fields.sorted(by: { $0.key < $1.key }) {
            let encoded = switch value {
            case let .string(s): json(s)
            case let .int(i): String(i)
            case let .bool(b): b ? "true" : "false"
            case .null: "null"
            }
            parts.append("\(json(key)):\(encoded)")
        }
        return "{\(parts.joined(separator: ","))}"
    }

    private static func json(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(string)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
