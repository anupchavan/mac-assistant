import Foundation

/// One question and its answer. Screenshots are never stored.
struct Turn: Codable, Identifiable, Equatable {
    var id = UUID()
    var ask: String
    var answer: String = ""
    /// Characters of `answer` actually heard; nil = all of it (typed, or speech finished).
    var spokenUpTo: Int?
    var language: String?
    var app: String
    var appLabel: String
    var bundleID: String
    var voice: Bool
    var at = Date()
    var workedFor: Double?
    var steps: [String] = []
    var error: String?
    /// "Now looking at Chrome · arxiv.org" when the app changed since the previous turn.
    var divider: String?

    /// What the model should remember: only what was actually heard or shown.
    var rememberedAnswer: String {
        guard let n = spokenUpTo, n < answer.count else { return answer }
        return String(answer.prefix(n)) + " …(interrupted)"
    }
}

struct Chat: Codable, Identifiable, Equatable {
    var id = UUID()
    var turns: [Turn] = []
    var updatedAt = Date()
    var title: String { turns.first?.ask ?? "New chat" }
}

/// Chats in ~/Library/Application Support/<bundle>/chats.json.
enum ChatStore {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.anup.assistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chats.json")
    }

    static func load() -> [Chat] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return ((try? d.decode([Chat].self, from: data)) ?? []).filter { !$0.turns.isEmpty }
    }

    static func save(_ chats: [Chat]) {
        let keep = chats.filter { !$0.turns.isEmpty }.suffix(50)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(Array(keep)) else { return }
        DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
    }
}
