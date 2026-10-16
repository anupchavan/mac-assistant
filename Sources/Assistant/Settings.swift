import AppKit
import SwiftUI

/// Settings (⌘,): paste API keys; they go to the Keychain and are used immediately.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Settings"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(Theme.background)
            let host = NSHostingView(rootView: SettingsView { [weak w] in w?.close() })
            host.sizingOptions = [.preferredContentSize]
            w.contentView = host
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let close: () -> Void
    @State private var sarvam = ""
    @State private var openAI = ""
    @State private var status = ""
    @State private var refresh = 0
    @State private var pace = SarvamTTS.pace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("API keys").font(Fonts.title).foregroundStyle(Theme.textPrimary)
                Text("Saved in your Keychain and used right away. An export in ~/.zshrc works too.")
                    .font(Fonts.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            KeyField(title: "Sarvam", hint: "Required", names: Keys.sarvamNames, text: $sarvam, refresh: refresh)
            KeyField(title: "OpenAI", hint: "Optional: clicking for you", names: Keys.openAINames, text: $openAI, refresh: refresh)
            Theme.separator.frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Voice speed").font(Fonts.bodyStrong).foregroundStyle(Theme.textPrimary)
                Picker("", selection: $pace) {
                    Text("Slower").tag(0.8)
                    Text("Normal").tag(0.9)
                    Text("Faster").tag(1.05)
                }
                .pickerStyle(.segmented).labelsHidden()
                .onChange(of: pace) { _, v in UserDefaults.standard.set(v, forKey: "ttsPace") }
            }
            HStack(spacing: 12) {
                Text(status).font(Fonts.body).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 8)
                Button("Done", action: close).buttonStyle(.plain)
                    .font(Fonts.body).foregroundStyle(Theme.textSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(action: save) {
                    HStack(spacing: 6) {
                        Text("Save").font(Fonts.bodyStrong).foregroundStyle(Theme.textPrimary)
                        Keycap(label: "↵")
                    }
                    // 32 tall, keycap inset 5: radius 11 = keycap 6 + 5, so the corners are concentric.
                    .padding(.leading, 14).padding(.trailing, 5).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.chipFill))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.chipBorder, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(sarvam.isEmpty && openAI.isEmpty)
            }
        }
        .padding(20)
        .padding(.top, 12)
        .frame(width: 440)
        .background(LinearGradient(colors: [Theme.background, Theme.backgroundSecondary], startPoint: .top, endPoint: .bottom))
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
    }

    private func save() {
        if !sarvam.isEmpty { Keys.save(sarvam, for: Keys.sarvamNames) }
        if !openAI.isEmpty { Keys.save(openAI, for: Keys.openAINames) }
        sarvam = ""; openAI = ""
        refresh += 1
        status = "Saved. Using it now."
        Log.info(Keys.report().replacingOccurrences(of: "\n", with: " · "))
    }
}

/// One key: label, where the current one comes from, and a secure field that is always empty
/// (a saved key is never shown back).
struct KeyField: View {
    let title: String
    let hint: String
    let names: [String]
    @Binding var text: String
    let refresh: Int
    @State private var removed = 0

    var body: some View {
        let source = { _ = refresh; _ = removed; return Keys.source(names) }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(Fonts.bodyStrong).foregroundStyle(Theme.textPrimary)
                Text(hint).font(Fonts.body).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Spacer(minLength: 8)
                Circle().fill(source == nil ? Theme.textQuaternary : Theme.done).frame(width: 6, height: 6)
                Text(source.map { "From \($0.rawValue)" } ?? "Missing").font(Fonts.body)
                    .foregroundStyle(source == nil ? Theme.textTertiary : Theme.textSecondary)
                if source == .settings {
                    Button("Remove") { Keys.save("", for: names); removed += 1 }
                        .buttonStyle(.plain).font(Fonts.body).foregroundStyle(Theme.link)
                }
            }
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(source == nil ? "Paste your key" : "Paste a new key to replace it")
                        .font(Fonts.body).foregroundStyle(Theme.textTertiary).allowsHitTesting(false)
                }
                SecureField("", text: $text)
                    .textFieldStyle(.plain).font(Fonts.body).foregroundStyle(Theme.textPrimary).tint(Theme.accent)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.chipBorder, lineWidth: 1))
        }
    }
}
