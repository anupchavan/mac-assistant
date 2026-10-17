import Foundation

public struct InputEnvelope: Sendable, Equatable {
    public var input: Input
    public var run: String?
    public init(_ input: Input, run: String? = nil) { self.input = input; self.run = run }
}

public enum JSONL {
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
