import AppKit
import SwiftUI

/// Settings (⌘,): a standard preferences window with toolbar tabs, like Music's.
/// One fixed size for every tab; the forms are grouped and sized to fit it.
@MainActor
final class SettingsWindow {
    static let size = NSSize(width: 500, height: 380)
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = []
            tabs.addTabViewItem(Self.tab("General", symbol: "gearshape", GeneralSettings()))
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
    @State private var hasDeepgramKey = Keys.deepgram != nil

    var body: some View {
        Form {
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
                Picker("Voice speed", selection: $pace) {
                    Text("Slower").tag(0.9)
                    Text("Normal").tag(1.0)
                    Text("Faster").tag(1.15)
                }
                .pickerStyle(.segmented)
                .onChange(of: pace) { _, v in UserDefaults.standard.set(v, forKey: "ttsPace") }
            }
        }
        .formStyle(.grouped)
        .onAppear { hasDeepgramKey = Keys.deepgram != nil }
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

// MARK: - API keys

struct KeysSettings: View {
    var body: some View {
        Form {
            Section {
                KeyRow(title: "Sarvam", hint: "Required: answers and voice", names: Keys.sarvamNames)
                KeyRow(title: "OpenAI", hint: "Optional: clicking for you", names: Keys.openAINames)
                KeyRow(title: "Deepgram", hint: "Optional: faster speech recognition", names: Keys.deepgramNames)
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
