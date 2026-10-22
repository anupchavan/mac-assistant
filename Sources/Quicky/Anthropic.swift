import Foundation

/// Claude on the Anthropic API (Haiku 5.5 for now). Takes the same OpenAI-style messages and tools as
/// SarvamChat and yields the same events, so the answer loop doesn't know which model it is talking to.
/// Served from Anthropic's own regions (not India), so expect ~200-300 ms more round trip than Vertex Mumbai.
enum Anthropic {
    static let keyNames = ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"]
    static var key: String? { Keys.lookup(keyNames) }
    static func isClaude(_ model: String) -> Bool { model.hasPrefix("claude-") }
    static var available: Bool { key != nil }
    static let host = URL(string: "https://api.anthropic.com/")!

    /// "auto" = adaptive thinking (Claude decides per ask whether to think and how much); "off" skips it.
    /// Effort sets how hard it tries: low for talk, the deep route asks for high.
    static var thinking: String { UserDefaults.standard.string(forKey: "claudeThinking") ?? Keys.setting("ASSISTANT_CLAUDE_THINKING", default: "auto") }
    static var effort: String { Keys.setting("ASSISTANT_CLAUDE_EFFORT", default: "low") }

    /// Thinking blocks must go back verbatim with the tool calls they led to, but the answer loop only keeps
    /// OpenAI-style text + tool_calls. So the whole assistant content of a tool-calling reply is kept here,
    /// keyed by its tool_use ids, and put back when that turn is replayed. Small and short-lived.
    private static let lock = NSLock()
    private static var replies: [String: [[String: Any]]] = [:]
    private static var order: [String] = []

    private static func remember(_ content: [[String: Any]]) {
        let ids = content.compactMap { $0["type"] as? String == "tool_use" ? $0["id"] as? String : nil }
        guard !ids.isEmpty, content.contains(where: { ["thinking", "redacted_thinking"].contains($0["type"] as? String) }) else { return }
        lock.lock(); defer { lock.unlock() }
        for id in ids { replies[id] = content; order.append(id) }
        while order.count > 64 { replies[order.removeFirst()] = nil }
    }

    private static func recall(_ ids: [String]) -> [[String: Any]]? {
        lock.lock(); defer { lock.unlock() }
        return ids.lazy.compactMap { replies[$0] }.first
    }

    static func stream(model: String, messages: [[String: Any]], tools: [[String: Any]]?, toolChoice: String,
                       reasoning: String?, maxTokens: Int) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard let key = Self.key else { throw APIError(status: 401, body: "Add an Anthropic key in Settings → API Keys.") }
                    var req = URLRequest(url: host.appendingPathComponent("v1/messages"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 60
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(key, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body(model: model, messages: messages, tools: tools,
                                                                                   toolChoice: toolChoice, reasoning: reasoning,
                                                                                   maxTokens: maxTokens))
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 2000 { break } }
                        throw APIError(status: status, body: text)
                    }
                    // The reply's content blocks, rebuilt from the stream, for the thinking replay above.
                    var blocks: [Int: [String: Any]] = [:]
                    var json: [Int: String] = [:]
                    var callOf: [Int: Int] = [:]     // block index → tool call index
                    var said = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:"),
                              let d = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let type = obj["type"] as? String else { continue }
                        let i = obj["index"] as? Int ?? 0
                        switch type {
                        case "content_block_start":
                            guard let block = obj["content_block"] as? [String: Any] else { continue }
                            blocks[i] = block
                            if block["type"] as? String == "tool_use" {
                                let n = callOf.count
                                callOf[i] = n
                                json[i] = ""
                                cont.yield(.toolCallDelta(index: n, id: block["id"] as? String, name: block["name"] as? String, arguments: nil))
                            }
                        case "content_block_delta":
                            guard let delta = obj["delta"] as? [String: Any] else { continue }
                            switch delta["type"] as? String {
                            case "text_delta":
                                let t = delta["text"] as? String ?? ""
                                blocks[i]?["text"] = (blocks[i]?["text"] as? String ?? "") + t
                                if !t.isEmpty { said = true; cont.yield(.text(t)) }
                            case "thinking_delta":
                                let t = delta["thinking"] as? String ?? ""
                                blocks[i]?["thinking"] = (blocks[i]?["thinking"] as? String ?? "") + t
                                if !t.isEmpty { cont.yield(.reasoning(t)) }
                            case "signature_delta":
                                blocks[i]?["signature"] = (blocks[i]?["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
                            case "input_json_delta":
                                let p = delta["partial_json"] as? String ?? ""
                                json[i, default: ""] += p
                                if let n = callOf[i], !p.isEmpty { cont.yield(.toolCallDelta(index: n, id: nil, name: nil, arguments: p)) }
                            default: break
                            }
                        case "content_block_stop":
                            if let raw = json[i] {
                                let input: Any = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? [String: Any]()
                                blocks[i]?["input"] = input
                            }
                        case "message_delta":
                            guard let stop = (obj["delta"] as? [String: Any])?["stop_reason"] as? String else { continue }
                            if stop == "refusal" && !said && callOf.isEmpty {
                                // Nothing was said: let the caller's fallback model answer instead of a blank turn.
                                throw APIError(status: 400, body: "Claude declined this request (refusal).")
                            }
                            remember(blocks.sorted { $0.key < $1.key }.map(\.value))
                            cont.yield(.finished(["tool_use": "tool_calls", "end_turn": "stop", "max_tokens": "length"][stop] ?? stop))
                        case "error":
                            let e = obj["error"] as? [String: Any]
                            throw APIError(status: (e?["type"] as? String) == "overloaded_error" ? 529 : 500,
                                           body: e?["message"] as? String ?? "Anthropic stream error")
                        default: break
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - OpenAI-style request → Messages API request

    static func body(model: String, messages: [[String: Any]], tools: [[String: Any]]?, toolChoice: String,
                     reasoning: String?, maxTokens: Int) -> [String: Any] {
        var system: [String] = []
        var out: [[String: Any]] = []
        func add(_ role: String, _ content: [[String: Any]]) {
            guard !content.isEmpty else { return }
            // Roles must alternate, and all tool results for one reply go back in a single user message.
            if let last = out.last, last["role"] as? String == role {
                out[out.count - 1]["content"] = (last["content"] as? [[String: Any]] ?? []) + content
            } else {
                out.append(["role": role, "content": content])
            }
        }
        for m in messages {
            switch m["role"] as? String ?? "user" {
            case "system":
                if let s = m["content"] as? String { system.append(s) }
            case "assistant":
                let calls = (m["tool_calls"] as? [[String: Any]]) ?? []
                let ids = calls.compactMap { $0["id"] as? String }
                if let kept = recall(ids) {
                    // Replay the reply as Claude sent it (thinking included), minus calls that weren't run.
                    let ran = Set(ids)
                    add("assistant", kept.filter { $0["type"] as? String != "tool_use" || ran.contains($0["id"] as? String ?? "") })
                    continue
                }
                var content: [[String: Any]] = []
                if let s = m["content"] as? String, !s.isEmpty { content.append(["type": "text", "text": s]) }
                for tc in calls {
                    let fn = tc["function"] as? [String: Any] ?? [:]
                    let input = (fn["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? [String: Any]()
                    content.append(["type": "tool_use", "id": tc["id"] as? String ?? "", "name": fn["name"] as? String ?? "", "input": input])
                }
                add("assistant", content)
            case "tool":
                add("user", [["type": "tool_result", "tool_use_id": m["tool_call_id"] as? String ?? "",
                              "content": (m["content"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(empty)"]])
            default:
                add("user", userContent(m["content"]))
            }
        }
        var effort = (reasoning ?? Self.effort).lowercased()
        if !["low", "medium", "high", "xhigh", "max"].contains(effort) { effort = "low" }
        // Thinking can only be turned off at effort high or below.
        let thinkingOff = thinking == "off" && !["xhigh", "max"].contains(effort)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": out,
            "thinking": ["type": thinkingOff ? "disabled" : "adaptive"],
            "output_config": ["effort": effort],
            // Caches tools + system + earlier turns; Quicky's system prompt never changes between turns.
            "cache_control": ["type": "ephemeral"],
        ]
        if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
        if let tools, !tools.isEmpty {
            body["tools"] = tools.compactMap { $0["function"] as? [String: Any] }.map { f -> [String: Any] in
                ["name": f["name"] ?? "", "description": f["description"] ?? "", "input_schema": f["parameters"] ?? ["type": "object"]]
            }
            body["tool_choice"] = ["type": toolChoice == "none" ? "none" : "auto"]
        }
        return body
    }

    private static func userContent(_ content: Any?) -> [[String: Any]] {
        if let s = content as? String { return s.isEmpty ? [] : [["type": "text", "text": s]] }
        return ((content as? [[String: Any]]) ?? []).compactMap { p in
            if let t = p["text"] as? String { return ["type": "text", "text": t] }
            // data:image/jpeg;base64,....
            if let url = (p["image_url"] as? [String: Any])?["url"] as? String, url.hasPrefix("data:"),
               let comma = url.firstIndex(of: ","), let semi = url.firstIndex(of: ";") {
                return ["type": "image", "source": ["type": "base64",
                                                    "media_type": String(url[url.index(url.startIndex, offsetBy: 5)..<semi]),
                                                    "data": String(url[url.index(after: comma)...])]]
            }
            return nil
        }
    }
}
