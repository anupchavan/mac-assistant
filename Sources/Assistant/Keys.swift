import Foundation

/// API keys come from the process environment, else from `export NAME=...` lines in ~/.zshrc
/// (an app launched from Finder doesn't inherit the shell's environment). Keys are never logged.
enum Keys {
    static let sarvamNames = ["SARVAM_API_KEY", "SARVAM_API_SUBSCRIPTION_KEY", "SARVAM_KEY", "SARVAM_AI_API_KEY"]
    static let openAINames = ["OPENAI_API_KEY", "OPENAI_KEY"]

    static var sarvam: String? { lookup(sarvamNames) }
    static var openAI: String? { lookup(openAINames) }

    private static var cache: [String: String]?

    static func lookup(_ names: [String]) -> String? {
        let env = ProcessInfo.processInfo.environment
        for n in names { if let v = env[n], !v.isEmpty { return v } }
        let file = shellExports()
        for n in names { if let v = file[n], !v.isEmpty { return v } }
        return nil
    }

    /// Drop the cached ~/.zshrc so the next lookup re-reads it (after a 401, or the menu's Reload Keys).
    static func reload() { cache = nil }

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
        func mark(_ v: String?) -> String { v == nil ? "missing" : "found (\(v!.count) chars)" }
        return "Sarvam key: \(mark(sarvam))\nOpenAI key: \(mark(openAI))"
    }
}
