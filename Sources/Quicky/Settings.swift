import AppKit
import AVFoundation
import SwiftUI

/// Settings (⌘,): a standard preferences window with toolbar tabs, like Music's.
/// One fixed size for every tab; General fits it, API Keys and Shortcuts scroll.
@MainActor
final class SettingsWindow {
    static let size = NSSize(width: 500, height: 450)
    private(set) var window: NSWindow?
    var onShortcutsChanged: (() -> Void)?

    func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = []
            tabs.addTabViewItem(Self.tab("General", symbol: "gearshape", GeneralSettings()))
            tabs.addTabViewItem(Self.tab("Shortcuts", symbol: "command", ShortcutsSettings { [weak self] in self?.onShortcutsChanged?() }))
            tabs.addTabViewItem(Self.tab("API Keys", symbol: "key", KeysSettings()))
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            w.setContentSize(Self.size)
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private static func tab<V: View>(_ title: String, symbol: String, _ view: V) -> NSTabViewItem {
        let host = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        host.sizingOptions = []
        host.preferredContentSize = size
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

// MARK: - General

struct GeneralSettings: View {
    @State private var stt = STT.chosen.rawValue
    @State private var pace = SarvamTTS.pace
    @State private var voice = TTS.chosen.rawValue
    @State private var hasElevenLabsKey = Keys.elevenLabs != nil
    @State private var hasDeepgramKey = Keys.deepgram != nil
    @State private var answer = UserDefaults.standard.string(forKey: "answerModel") ?? "sarvam-105b"
    @State private var hasGemini = Gemini.available

    var body: some View {
        Form {
            Section("Answering") {
                Picker(selection: $answer) {
                    ForEach(Gemini.choices, id: \.id) { Text($0.label).tag($0.id) }
                } label: {
                    Text("Answer model")
                    Text(answerNote)
                }
                .pickerStyle(.menu)
                .onChange(of: answer) { _, v in UserDefaults.standard.set(v, forKey: "answerModel") }
            }
            Section("Listening") {
                Picker(selection: $stt) {
                    Text("Deepgram Nova-3").tag(STT.Provider.deepgram.rawValue)
                    Text("Sarvam Saaras v4").tag(STT.Provider.sarvam.rawValue)
                } label: {
                    Text("Speech recognition")
                    Text(sttNote)   // second label line: the form shows it as a subtitle under the title
                }
                .pickerStyle(.menu)
                .onChange(of: stt) { _, v in UserDefaults.standard.set(v, forKey: "sttProvider") }
            }
            Section("Speaking") {
                Picker(selection: $voice) {
                    Text("Sarvam Bulbul v3").tag(TTS.Provider.sarvam.rawValue)
                    Text("ElevenLabs v4 Turbo").tag(TTS.Provider.elevenLabsTurbo.rawValue)
                    Text("ElevenLabs v4").tag(TTS.Provider.elevenLabs.rawValue)
                } label: {
                    Text("Voice")
                    Text(voiceNote)
                }
                .pickerStyle(.menu)
                .onChange(of: voice) { _, v in UserDefaults.standard.set(v, forKey: "ttsProvider") }
                // Eleven v4 has no speed control; it always speaks at its natural pace.
                if voice == TTS.Provider.sarvam.rawValue {
                    Picker("Voice speed", selection: $pace) {
                        Text("Slower").tag(0.9)
                        Text("Normal").tag(1.0)
                        Text("Faster").tag(1.15)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: pace) { _, v in UserDefaults.standard.set(v, forKey: "ttsPace") }
                }
            }
            PermissionsSection()
        }
        .formStyle(.grouped)
        .onAppear { hasDeepgramKey = Keys.deepgram != nil; hasGemini = Gemini.available; hasElevenLabsKey = Keys.elevenLabs != nil }
    }

    private var answerNote: String {
        if answer.hasPrefix("aistudio/") {
            return Keys.aiStudio != nil
                ? "Gemini API (AI Studio), served outside India, so slower. Also reads screenshots. Falls back to Sarvam if it fails."
                : "Add a Gemini API key in API Keys to use it. Sarvam until then."
        }
        guard answer.hasPrefix("gemini") else { return "Sarvam, India servers. Screenshots go to gemma4." }
        return hasGemini
            ? "Vertex AI in Mumbai, thinking minimal. Also reads screenshots. Falls back to Sarvam if it fails."
            : "Add a Google Cloud key and project ID in API Keys to use it. Sarvam until then."
    }

    private var voiceNote: String {
        guard voice != TTS.Provider.sarvam.rawValue else { return "Sarvam, India servers. Hindi, Telugu and nine more Indian languages." }
        guard hasElevenLabsKey else { return "Add an ElevenLabs key in API Keys to use it. Bulbul until then." }
        return voice == TTS.Provider.elevenLabsTurbo.rawValue
            ? "Clara, and she can sigh or laugh. Starts about as fast as Bulbul."
            : "Clara at full quality, sighs and laughs included. Starts about half a second later."
    }

    private var sttNote: String {
        if stt == STT.Provider.deepgram.rawValue {
            return hasDeepgramKey
                ? "Fastest, English only, India servers. If Deepgram fails, Sarvam takes over mid-sentence."
                : "Add a Deepgram key in API Keys to use it. Sarvam until then."
        }
        return "Understands English, Hindi, Telugu and mixed speech."
    }
}

/// What macOS has granted, each with a way to the right Privacy pane (it moved here from the menu bar).
struct PermissionsSection: View {
    @State private var tick = 0     // re-reads the grants every 2 s while the tab is open
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let perms: [(String, Bool, String)] = [
            ("Accessibility", AXIsProcessTrusted(), "Privacy_Accessibility"),
            ("Input Monitoring", CGPreflightListenEventAccess(), "Privacy_ListenEvent"),
            ("Screen Recording", CGPreflightScreenCaptureAccess(), "Privacy_ScreenCapture"),
            ("Microphone", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Privacy_Microphone"),
        ]
        Section("Permissions") {
            ForEach(perms, id: \.0) { name, ok, pane in
                LabeledContent(name) {
                    if ok {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
        }
        .onReceive(timer) { _ in tick += 1 }
    }
}

// MARK: - Shortcuts

/// The trigger key is real; its gestures follow it. Panel keys are fixed, and the rest is the design's
/// grammar, shown greyed until it is built.
struct ShortcutsSettings: View {
    let changed: () -> Void
    @State private var trigger = TriggerKey.chosen
    @State private var capsLock = UserDefaults.standard.bool(forKey: CapsLockHyper.defaultsKey)
    private let external = CapsLockHyper.externalSource

    var body: some View {
        let k = trigger.symbol
        Form {
            Section {
                Picker(selection: $trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Trigger key")
                    Text(trigger.note)
                }
                .pickerStyle(.menu)
                .onChange(of: trigger) { _, v in UserDefaults.standard.set(v.rawValue, forKey: TriggerKey.defaultsKey); changed() }
                if trigger == .hyper {
                    if let external {
                        LabeledContent {
                            Text("From \(external)").foregroundStyle(.secondary)
                        } label: {
                            Text("Caps Lock as Hyperkey")
                            Text("Quicky listens and leaves Caps Lock alone.")
                        }
                    } else {
                        Toggle(isOn: $capsLock) {
                            Text("Caps Lock as Hyperkey")
                            Text("Quicky turns Caps Lock into ⌘⌃⌥⇧. Leave it off if Raycast's Hyper Key already does.")
                        }
                        .onChange(of: capsLock) { _, v in UserDefaults.standard.set(v, forKey: CapsLockHyper.defaultsKey); changed() }
                    }
                }
            }
            Section("Anywhere") {
                ShortcutRow("Talk while holding", hold: true, keys: [k])
                ShortcutRow("Talk hands-free", keys: [k, k])
                ShortcutRow("Type a question", keys: ["⇧", k])
                ShortcutRow("New chat", keys: ["⌥", k])
            }
            Section("In the panel") {
                ShortcutRow("New chat", keys: ["⌘", "N"])
                ShortcutRow("Previous chat", keys: ["⌘", "["])
                ShortcutRow("Next chat", keys: ["⌘", "]"])
                ShortcutRow("Stop or close", keys: ["esc"])
            }
            Section("Coming soon") {
                ShortcutRow("Switch what “this” points at", keys: ["↑", "↓"])
                ShortcutRow("Apply a suggested edit", keys: ["⏎"])
                ShortcutRow("See your original", hold: true, keys: ["⌥"])
                ShortcutRow("Peek a link", keys: ["⇧", "click"])
                ShortcutRow("Show all chats", hold: true, keys: ["⌘"])
            }
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// A title on the left, key caps on the right ("Hold" in front for a held key).
struct ShortcutRow: View {
    let title: String
    let hold: Bool
    let keys: [String]
    init(_ title: String, hold: Bool = false, keys: [String]) { self.title = title; self.hold = hold; self.keys = keys }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                if hold { Text("Hold").foregroundStyle(.secondary).padding(.trailing, 2) }
                ForEach(Array(keys.enumerated()), id: \.offset) { KeyCap(text: $0.element) }
            }
        }
    }
}

/// Fixed 22 pt tall cap with the same 6 pt inset on both sides; a single symbol is a 22 pt square.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            // ✦ is a solid fallback glyph that reads heavier than ⌘ at 11; 10 matches it.
            .font(.system(size: text == "✦" ? 10 : 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22, maxHeight: 22)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
    }
}

// MARK: - API keys

struct KeysSettings: View {
    var body: some View {
        Form {
            Section {
                KeyRow(title: "Sarvam", hint: "Required: answers and voice", names: Keys.sarvamNames)
                KeyRow(title: "OpenAI", hint: "Optional: clicking for you", names: Keys.openAINames)
                KeyRow(title: "Deepgram", hint: "Optional: faster speech recognition", names: Keys.deepgramNames)
                KeyRow(title: "Google Cloud", hint: "Optional: Gemini answers from Mumbai", names: Keys.vertexNames)
                KeyRow(title: "Gemini API", hint: "Optional: Gemini 3.8 Flash from AI Studio", names: Keys.aiStudioNames)
                ProjectRow()
                KeyRow(title: "ElevenLabs", hint: "Optional: the expressive Eleven v4 voice", names: Keys.elevenLabsNames)
            } footer: {
                Text("Saved in your Keychain and used right away. An export in ~/.zshrc works too.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

/// One key: where the current one comes from, and a field that is always empty
/// (a saved key is never shown back). Return or Save stores it.
struct KeyRow: View {
    let title: String
    let hint: String
    let names: [String]
    @State private var text = ""
    @State private var source: Keys.Source?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(hint).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Circle().fill(source == nil ? Color.secondary.opacity(0.5) : Color.green).frame(width: 7, height: 7)
                    Text(source.map { "From \($0.rawValue)" } ?? "Missing").foregroundStyle(.secondary)
                }
                if source == .settings {
                    Button("Remove") { Keys.save("", for: names); reload() }.buttonStyle(.link)
                }
            }
            HStack(spacing: 8) {
                SecureField("", text: $text, prompt: Text(source == nil ? "Paste your key" : "Paste a new key to replace it"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(save)
                Button("Save", action: save).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, 2)
        .onAppear(perform: reload)
    }

    private func reload() { source = Keys.source(names) }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Keys.save(text, for: names)
        text = ""
        reload()
        Log.info(Keys.report().replacingOccurrences(of: "\n", with: " · "))
    }
}

/// The Google Cloud project that owns the key (an ID, not a secret, so it's shown and kept in defaults).
struct ProjectRow: View {
    @State private var text = UserDefaults.standard.string(forKey: "googleCloudProject") ?? ""

    var body: some View {
        TextField(text: $text, prompt: Text("my-project-123")) {
            Text("Google Cloud project ID")
            Text("Region asia-south1 (Mumbai)").font(.callout).foregroundStyle(.secondary)
        }
        .onChange(of: text) { _, v in
            UserDefaults.standard.set(v.trimmingCharacters(in: .whitespaces), forKey: "googleCloudProject")
        }
    }
}
