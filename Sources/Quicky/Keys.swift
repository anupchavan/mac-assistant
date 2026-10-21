import Foundation
import Security

/// API keys come from the Keychain (saved in Settings), else the process environment, else
/// `export NAME=...` lines in ~/.zshrc (an app launched from Finder doesn't inherit the shell's
/// environment). Keys are never logged.
enum Keys {
    enum Source: String { case settings = "Settings", environment = "environment", zshrc = "~/.zshrc" }
    static let sarvamNames = ["SARVAM_API_KEY", "SARVAM_API_SUBSCRIPTION_KEY", "SARVAM_KEY", "SARVAM_AI_API_KEY"]
    static let openAINames = ["OPENAI_API_KEY", "OPENAI_KEY"]
    static let mistralNames = ["MISTRAL_API_KEY"]

    static var sarvam: String? { lookup(sarvamNames) }
    static var openAI: String? { lookup(openAINames) }
    static var mistral: String? { lookup(mistralNames) }

    private static var cache: [String: String]?

    static func lookup(_ names: [String]) -> String? { find(names)?.value }

    /// Where a key was found, for the Settings window and the menu. Never the value.
    static func source(_ names: [String]) -> Source? { find(names)?.source }

    private static func find(_ names: [String]) -> (value: String, source: Source)? {
        if [sarvamNames, openAINames, mistralNames].contains(names), let v = Keychain.get(names[0]), !v.isEmpty { return (v, .settings) }
        let env = ProcessInfo.processInfo.environment
        for n in names { if let v = env[n], !v.isEmpty { return (v, .environment) } }
        let file = shellExports()
        for n in names { if let v = file[n], !v.isEmpty { return (v, .zshrc) } }
        return nil
    }

    /// Drop the cached ~/.zshrc so the next lookup re-reads it (after a 401, or the menu's Reload Keys).
    static func reload() { cache = nil; Keychain.clearCache() }

    /// Settings → Save. An empty value removes the saved key (falls back to env / ~/.zshrc).
    static func save(_ value: String, for names: [String]) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { Keychain.delete(names[0]) } else { Keychain.set(v, for: names[0]) }
        reload()
    }

    /// Generic settings (model names, voice) use the same lookup so they can be overridden from the shell.
    static func setting(_ name: String, default def: String) -> String {
        lookup([name]) ?? def
    }

    static func shellExports() -> [String: String] {
        if let c = cache { return c }
        var out: [String: String] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser
        // The shell's own order, and the last assignment wins (a key re-exported lower down replaces the old one).
        for name in [".profile", ".bash_profile", ".zshenv", ".zprofile", ".zshrc"] {
            guard let text = try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n") {
                var line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#") else { continue }
                if line.hasPrefix("export ") { line.removeFirst(7) } else { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if let hash = value.range(of: " #"), !value.hasPrefix("\"") && !value.hasPrefix("'") {
                    value = String(value[..<hash.lowerBound])
                }
                if value.count >= 2, let f = value.first, let l = value.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                    value = String(value.dropFirst().dropLast())
                }
                // Skip values that need the shell to expand them.
                if value.contains("$(") || value.hasPrefix("$") { continue }
                out[key] = value
            }
        }
        cache = out
        return out
    }

    /// For `--probe keys`: which keys were found, never their values.
    static func report() -> String {
        func mark(_ names: [String]) -> String {
            guard let f = find(names) else { return "missing" }
            return "found in \(f.source.rawValue) (\(f.value.count) chars)"
        }
        return "Provider: \(Provider.current.name)\nSarvam key: \(mark(sarvamNames))\nMistral key: \(mark(mistralNames))\nOpenAI key: \(mark(openAINames))"
    }
}

/// Generic passwords under service dev.anup.assistant. Never shows Keychain UI (a probe or an
/// unsigned build just doesn't see the saved keys instead of prompting).
enum Keychain {
    static let service = "dev.anup.assistant"
    private static let lock = NSLock()
    private static var cache: [String: String?] = [:]

    static func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[account] { return hit }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var out: CFTypeRef?
        let value = SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cache[account] = value
        return value
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            if status != errSecSuccess { Log.error("keychain save failed (\(status))") }
        }
    }

    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    static func clearCache() { lock.lock(); cache = [:]; lock.unlock() }
}
