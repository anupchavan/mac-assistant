import Foundation

public struct InputEnvelope: Sendable, Equatable {
    public var input: Input
    public var run: String?
    public init(_ input: Input, run: String? = nil) { self.input = input; self.run = run }
}

public enum JSONL {
    static func verificationHelloIsValid(_ line: String, token: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["type"] as? String == "hello" && object["token"] as? String == token
    }

    static func verificationNoticeMatches(_ notice: Notice, runs: Set<String>) -> Bool {
        guard let run = notice.run else { return false }
        return runs.contains(run)
    }

    public static func encode(_ envelope: InputEnvelope) throws -> String {
        var pairs: [(String, NoticeValue)]
        switch envelope.input {
        case .submit(let text): pairs = [("type", .string("ask")), ("text", .string(text))]
        case .escape: pairs = [("type", .string("escape"))]
        case .dismiss(.clickOutside(let userScrolled)):
            pairs = [("type", .string("dismiss")), ("user_scrolled", .bool(userScrolled))]
        case .dismiss(.otherAppActivated): throw JSONLError.invalidInput
        case .command(let command):
            let value = switch command {
            case .retry: "retry"
            case .previousChat: "previous_chat"
            case .nextChat: "next_chat"
            case .newChat: "new_chat"
            }
            pairs = [("type", .string("command")), ("command", .string(value))]
        case .key(let key):
            switch key {
            case .fnDown(let shift):
                pairs = [("type", .string("key")), ("key", .string("fn_down")), ("shift", .bool(shift))]
            case .fnUp: pairs = [("type", .string("key")), ("key", .string("fn_up"))]
            case .shiftDown: pairs = [("type", .string("key")), ("key", .string("shift_down"))]
            case .keyDown(let code):
                pairs = [("type", .string("key")), ("key", .string("key_down")), ("code", .int(code))]
            }
        }
        if let run = envelope.run { pairs.insert(("run", .string(run)), at: 1) }
        return "{" + pairs.map { jsonString($0.0) + ":" + encodeValue($0.1) }.joined(separator: ",") + "}"
    }

    public static func encode(_ notice: Notice) throws -> String {
        var pairs = [("type", NoticeValue.string(notice.type))]
        if let run = notice.run { pairs.append(("run", .string(run))) }
        pairs += notice.fields.keys.sorted().map { ($0, notice.fields[$0]!) }
        return "{" + pairs.map { jsonString($0.0) + ":" + encodeValue($0.1) }.joined(separator: ",") + "}"
    }

    public static func decode(_ line: String) throws -> InputEnvelope {
        guard let data = line.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String else { throw JSONLError.invalidInput }
        let run = object["run"] as? String
        switch type {
        case "ask": guard let text = object["text"] as? String else { throw JSONLError.invalidInput }; return InputEnvelope(.submit(text), run: run)
        case "escape": return InputEnvelope(.escape, run: run)
        case "dismiss": return InputEnvelope(.dismiss(.clickOutside(userScrolled: object["user_scrolled"] as? Bool ?? false)), run: run)
        case "command":
            guard let value = object["command"] as? String else { throw JSONLError.invalidInput }
            let command: Command = switch value { case "retry": .retry; case "previous_chat": .previousChat; case "next_chat": .nextChat; case "new_chat": .newChat; default: throw JSONLError.invalidInput }
            return InputEnvelope(.command(command), run: run)
        case "key":
            guard let value = object["key"] as? String else { throw JSONLError.invalidInput }
            let key: Key = switch value { case "fn_down": .fnDown(shift: object["shift"] as? Bool ?? false); case "fn_up": .fnUp; case "shift_down": .shiftDown; case "key_down": .keyDown(code: object["code"] as? Int ?? -1); default: throw JSONLError.invalidInput }
            return InputEnvelope(.key(key), run: run)
        default: throw JSONLError.invalidInput
        }
    }

    @MainActor
    public static func run(engine: Engine, inputs: [InputEnvelope], emit: @MainActor @escaping (Notice) -> Void) async -> Int {
        await withCheckedContinuation { continuation in
            var resumed = false
            var exitCode = 0
            engine.onNotice = { notice in
                emit(notice)
                if notice.type == "done", case let .string(outcome) = notice.fields["outcome"] {
                    exitCode = outcome == "cancelled" || outcome == "stopped" ? 2 : outcome == "failed" ? 1 : 0
                }
                if notice.type == "quiet", !resumed { resumed = true; continuation.resume(returning: exitCode) }
            }
            for input in inputs { engine.send(input.input, run: input.run) }
        }
    }

    private static func encodeValue(_ value: NoticeValue) -> String {
        switch value { case let .string(v): jsonString(v); case let .int(v): String(v); case let .bool(v): v ? "true" : "false"; case .null: "null" }
    }
    private static func jsonString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value); return String(data: data, encoding: .utf8)!
    }
}

public enum JSONLError: Error { case invalidInput }
