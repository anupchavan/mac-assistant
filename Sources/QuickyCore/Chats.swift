import Foundation

public struct TurnRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var ask: String
    public var answer: String
    public var outcome: String
    public var retry: Bool
    public var date: Date

    public init(id: String, ask: String, answer: String, outcome: String, retry: Bool, date: Date) {
        self.id = id; self.ask = ask; self.answer = answer; self.outcome = outcome; self.retry = retry; self.date = date
    }
}

public struct Chat: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var turns: [TurnRecord]
    public var lastUsed: Date
    public init(id: String, turns: [TurnRecord] = [], lastUsed: Date) { self.id = id; self.turns = turns; self.lastUsed = lastUsed }
}

public enum ChatAction: Sendable, Equatable { case continueOrNew, previous, next, new, append(TurnRecord) }

public struct ChatLog: Sendable, Equatable, Codable {
    public static let continueWindow: TimeInterval = 300
    public private(set) var chats: [Chat]
    public private(set) var selected: Int
    private var nextID: Int

    public init(chats: [Chat] = [], selected: Int = 0, nextID: Int = 1) {
        self.chats = chats; self.selected = min(max(0, selected), max(0, chats.count - 1)); self.nextID = nextID
    }

    public var current: Chat? { chats.indices.contains(selected) ? chats[selected] : nil }
    public var position: String? { chats.isEmpty ? nil : "\(selected + 1) of \(chats.count)" }

    @discardableResult
    public mutating func apply(_ action: ChatAction, at now: Date) -> Chat? {
        switch action {
        case .continueOrNew:
            if let current, now.timeIntervalSince(current.lastUsed) <= Self.continueWindow { return current }
            return makeNew(at: now)
        case .previous:
            if selected > 0 { selected -= 1 }
        case .next:
            if selected + 1 < chats.count { selected += 1 }
        case .new:
            return makeNew(at: now)
        case let .append(record):
            if chats.isEmpty { _ = makeNew(at: now) }
            chats[selected].turns.append(record); chats[selected].lastUsed = now
            trim()
        }
        return current
    }

    public func history(limit: Int = 6) -> [ChatMessage] {
        guard let current else { return [] }
        return current.turns.filter { $0.outcome == "answered" && !$0.answer.isEmpty }.suffix(limit).flatMap {
            [ChatMessage(role: "user", content: $0.ask), ChatMessage(role: "assistant", content: $0.answer)]
        }
    }

    private mutating func makeNew(at now: Date) -> Chat {
        let chat = Chat(id: "c\(nextID)", lastUsed: now); nextID += 1
        chats.append(chat); selected = chats.count - 1; trim(); return chats[selected]
    }

    private mutating func trim() {
        if chats.count > 50 {
            let removed = chats.count - 50; chats.removeFirst(removed); selected = max(0, selected - removed)
        }
    }
}

public struct StoredState: Sendable, Equatable, Codable {
    public var revision: Int
    public var chats: ChatLog
    public init(revision: Int, chats: ChatLog) { self.revision = revision; self.chats = chats }
}

public actor Store {
    private let directory: URL
    private var newestRevision = -1
    public init(directory: URL) { self.directory = directory }

    public func load() -> StoredState? {
        let url = directory.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder.stable.decode(StoredState.self, from: data) else { return nil }
        newestRevision = max(newestRevision, state.revision); return state
    }

    @discardableResult
    public func write(_ state: StoredState) throws -> Bool {
        if newestRevision < 0, let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")), let disk = try? JSONDecoder.stable.decode(StoredState.self, from: data) {
            newestRevision = disk.revision
        }
        guard state.revision > newestRevision else { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.stable.encode(state)
        try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        newestRevision = state.revision
        return true
    }
}

extension JSONEncoder {
    static var stable: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
}

extension JSONDecoder {
    static var stable: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
