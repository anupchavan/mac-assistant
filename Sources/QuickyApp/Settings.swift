import AppKit
import Security
import SwiftUI
import QuickyCore

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @State private var key = ""
    @State private var status = SarvamKey.isSaved() ? "A key is saved." : "No key saved."

    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sarvam API key")
            SecureField("Paste your key", text: $key).onSubmit(save)
            HStack {
                Text(status).foregroundStyle(.secondary)
                Spacer()
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        let status = SarvamKey.save(trimmed)
        key = ""
        self.status = status == errSecSuccess
            ? "Saved."
            : "Couldn't save: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")"
    }
}

enum SarvamKey {
    private static var item: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: Keys.service, kSecAttrAccount: Keys.account]
    }

    static func save(_ key: String) -> OSStatus {
        SecItemDelete(item as CFDictionary)
        var add = item
        add[kSecValueData] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func isSaved() -> Bool {
        let status = SecItemCopyMatching(item as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}
