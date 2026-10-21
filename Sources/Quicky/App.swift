import AppKit
import AVFoundation
import ApplicationServices

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
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
        model.hotkey.start()
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

    private func requestPermissions() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: Menu (rebuilt each time it opens so permission states are current)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            return i
        }
        menu.addItem(item("Ask (hold fn)", #selector(askTyped)))
        menu.addItem(item("New Chat", #selector(newChat)))
        menu.addItem(.separator())

        let perms: [(String, Bool, String)] = [
            ("Accessibility", AXIsProcessTrusted(), "Privacy_Accessibility"),
            ("Input Monitoring", CGPreflightListenEventAccess(), "Privacy_ListenEvent"),
            ("Screen Recording", CGPreflightScreenCaptureAccess(), "Privacy_ScreenCapture"),
            ("Microphone", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Privacy_Microphone"),
        ]
        for (name, ok, pane) in perms {
            let i = item("\(ok ? "✓" : "✗")  \(name)", ok ? nil : #selector(openPrivacy(_:)))
            i.representedObject = pane
            menu.addItem(i)
        }
        let keys = item(Keys.sarvam == nil ? "✗  Sarvam key (add it in Settings…)" : "✓  Sarvam key", Keys.sarvam == nil ? #selector(openSettings) : nil)
        menu.addItem(keys)
        menu.addItem(item(Keys.openAI == nil ? "✗  OpenAI key (computer use off)" : "✓  OpenAI key", nil))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Reload Keys", #selector(reloadKeys)))
        menu.addItem(.separator())
        let right = item("Use right ⌥ instead of fn", #selector(toggleRightOption))
        right.state = model.hotkey.useRightOption ? .on : .off
        menu.addItem(right)
        let vision = item("Use screenshots with gemma4", #selector(toggleVision))
        vision.state = (UserDefaults.standard.object(forKey: "visionAvailable") as? Bool ?? true) ? .on : .off
        menu.addItem(vision)
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    @objc private func askTyped() { model.showTyped() }
    @objc private func newChat() { model.newChat(); model.showTyped() }
    @objc private func openSettings() { settings.show() }
    @objc private func reloadKeys() { Keys.reload(); Log.info(Keys.report().replacingOccurrences(of: "\n", with: " · ")) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleRightOption() {
        model.hotkey.useRightOption.toggle()
        UserDefaults.standard.set(model.hotkey.useRightOption, forKey: "useRightOption")
    }

    @objc private func toggleVision() {
        let on = UserDefaults.standard.object(forKey: "visionAvailable") as? Bool ?? true
        UserDefaults.standard.set(!on, forKey: "visionAvailable")
        Log.info("vision \(!on ? "on" : "off")")
    }

    @objc private func openPrivacy(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? String,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
