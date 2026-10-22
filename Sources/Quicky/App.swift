import AppKit
import AVFoundation
import ApplicationServices

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--extension") {
            exit(ExtensionHost.cli(Array(args.dropFirst(i + 1))))
        }
        if let i = args.firstIndex(of: "--probe") {
            Probe.run(Array(args.dropFirst(i + 1)))
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, never in the Dock
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var controller: PanelController!
    private var statusItem: NSStatusItem!
    private let settings = SettingsWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.register()
        DispatchQueue.global(qos: .utility).async { AppIndex.load() }
        model = AppModel()
        controller = PanelController(model: model)
        model.controller = controller

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.button?.setAccessibilityLabel("Quicky")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        requestPermissions()
        model.hotkey.reloadTrigger()
        model.hotkey.start()
        settings.onShortcutsChanged = { [weak self] in self?.model.hotkey.reloadTrigger() }
        // Rebuild the tap whenever Accessibility or Input Monitoring changes, so a grant works without
        // a relaunch (a tap made before the grant can stay listen-only or get no fn events).
        var granted = (AXIsProcessTrusted(), CGPreflightListenEventAccess())
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = (AXIsProcessTrusted(), CGPreflightListenEventAccess())
                guard now != granted else { return }
                Log.info("permissions now accessibility=\(now.0) inputMonitoring=\(now.1); restarting the event tap")
                granted = now
                self.model.hotkey.stop()
                self.model.hotkey.start()
            }
        }
        Task { await ContextCapture.warmUp() }
        if Keys.sarvam == nil { settings.show() }      // first run with no key anywhere
        Log.info(Keys.report().replacingOccurrences(of: "\n", with: " · "))
    }

    func applicationWillTerminate(_ notification: Notification) {
        if model.hotkey.capsLockHyper { CapsLockHyper.apply(false) }   // give Caps Lock back
    }

    private func requestPermissions() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: Menu (rebuilt each time it opens so the trigger key is current)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            if #available(macOS 27, *) { i.preferredImageVisibility = .hidden }   // no automatic gear on Settings…
            return i
        }
        // The trigger gestures can't be menu key equivalents, so they live in Settings › Shortcuts.
        menu.addItem(item("New Chat", #selector(newChat)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Quicky", #selector(quit), key: "q"))
    }

    @objc private func newChat() { model.newChat(); model.showTyped() }
    @objc private func openSettings() { settings.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
