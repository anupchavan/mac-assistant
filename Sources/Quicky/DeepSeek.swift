import Foundation

/// DeepSeek V4.1 Flash on DeepSeek's own API (OpenAI-compatible, served from China, so expect a longer
/// round trip than Mumbai). `deepseek-flash` is DeepSeek's id for V4.1-Flash-1017. Text only here:
/// screenshot asks go to gemma4.
enum DeepSeek {
    static let keyNames = ["DEEPSEEK_API_KEY"]
    static var key: String? { Keys.lookup(keyNames) }
    static func isDeepSeek(_ model: String) -> Bool { model.hasPrefix("deepseek-") }
    static var available: Bool { key != nil }
    static let host = URL(string: "https://api.deepseek.com/")!

    /// Thinking is off for talk (it thinks for hundreds of tokens otherwise); the deep route turns it on.
    /// ASSISTANT_DEEPSEEK_EFFORT=low|high|max turns it on for every ask.
    static var effort: String? {
        let v = Keys.setting("ASSISTANT_DEEPSEEK_EFFORT", default: "off").lowercased()
        return v == "off" ? nil : v
    }

    /// With tools and thinking on, DeepSeek wants each tool-calling reply's reasoning_content back on later
    /// requests (400 otherwise). The answer loop doesn't keep it, so it's held here by tool call id.
    private static let lock = NSLock()
    private static var reasoningByCall: [String: String] = [:]
    private static var order: [String] = []

    private static func remember(_ reasoning: String, for ids: [String]) {
        guard !reasoning.isEmpty, !ids.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for id in ids { reasoningByCall[id] = reasoning; order.append(id) }
        while order.count > 64 { reasoningByCall[order.removeFirst()] = nil }
    }

    static func withReasoning(_ messages: [[String: Any]]) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return messages.map { m in
            guard m["role"] as? String == "assistant",
                  let ids = (m["tool_calls"] as? [[String: Any]])?.compactMap({ $0["id"] as? String }),
                  let r = ids.lazy.compactMap({ reasoningByCall[$0] }).first else { return m }
            var out = m
            out["reasoning_content"] = r
            return out
        }
    }

    static func body(model: String, messages: [[String: Any]], tools: [[String: Any]]?, toolChoice: String,
                     reasoning: String?, maxTokens: Int) -> [String: Any] {
        var body: [String: Any] = ["model": model, "messages": withReasoning(messages), "stream": true, "max_tokens": maxTokens]
        if let tools, !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = toolChoice }
        if let effort = reasoning ?? effort {
            body["thinking"] = ["type": "enabled"]
            body["reasoning_effort"] = ["low", "high", "max"].contains(effort) ? effort : "high"
        } else {
            body["thinking"] = ["type": "disabled"]
        }
        return body
    }

    static func stream(model: String, messages: [[String: Any]], tools: [[String: Any]]?, toolChoice: String,
                       reasoning: String?, maxTokens: Int) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard let key = Self.key else { throw APIError(status: 401, body: "Add a DeepSeek key in Settings → API Keys.") }
                    var req = URLRequest(url: host.appendingPathComponent("chat/completions"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 60
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
                    var reasoningText = ""
                    var callIds: [String] = []
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
                        let delta = choice["delta"] as? [String: Any] ?? [:]
                        if let r = delta["reasoning_content"] as? String, !r.isEmpty { reasoningText += r; cont.yield(.reasoning(r)) }
                        if let c = delta["content"] as? String, !c.isEmpty { cont.yield(.text(c)) }
                        for tc in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                            let fn = tc["function"] as? [String: Any]
                            if let id = tc["id"] as? String { callIds.append(id) }
                            cont.yield(.toolCallDelta(index: tc["index"] as? Int ?? 0, id: tc["id"] as? String,
                                                      name: fn?["name"] as? String, arguments: fn?["arguments"] as? String))
                        }
                        if let f = choice["finish_reason"] as? String {
                            remember(reasoningText, for: callIds)
                            cont.yield(.finished(f))
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
}
