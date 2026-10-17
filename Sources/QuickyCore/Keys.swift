import Foundation
import Security

public enum Keys {
    public static let service = "dev.anup.assistant"
    public static let account = "SARVAM_API_KEY"

    public static func reload() -> String? {
        keychainValue() ?? ProcessInfo.processInfo.environment[account] ?? shellValue(account)
    }

    public static func setting(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name] ?? shellValue(name)
    }

    private static func keychainValue() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func shellValue(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = [".zprofile", ".zshrc", ".bash_profile", ".profile"]
        var found: String?
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"^\s*export\s+"# + escaped + #"\s*=\s*(.*?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for file in files {
            guard let text = try? String(contentsOf: home.appendingPathComponent(file), encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \ .isNewline).map(String.init) {
                let range = NSRange(line.startIndex..., in: line)
                guard let match = regex.firstMatch(in: line, range: range),
                      let valueRange = Range(match.range(at: 1), in: line) else { continue }
                var value = String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.contains("$(") || value.range(of: #"\$[A-Za-z_{]"#, options: .regularExpression) != nil { continue }
                if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                    value.removeFirst(); value.removeLast()
                }
                found = value
            }
        }
        return found
    }
}
