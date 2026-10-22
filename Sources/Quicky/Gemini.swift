import Foundation

/// Gemini on Vertex AI, served from Mumbai (asia-south1) so the round trip stays in India.
/// Takes the same OpenAI-style messages and tools as SarvamChat and yields the same events, so the
/// answer loop doesn't know which model it is talking to. Auth is a Google Cloud API key bound to a
/// service account (express-mode keys only reach the global endpoint, which is far from India).
enum Gemini {
    static let choices: [(id: String, label: String)] = [
        ("sarvam-105b", "Sarvam 105B"),
        ("gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite"),
        ("gemini-3.5-flash", "Gemini 3.5 Flash"),
    ]
    static var location: String { Keys.setting("GOOGLE_CLOUD_LOCATION", default: "asia-south1") }
    static var project: String? {
        let v = (UserDefaults.standard.string(forKey: "googleCloudProject") ?? Keys.lookup(["GOOGLE_CLOUD_PROJECT"]) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
    static var available: Bool { Keys.vertex != nil && project != nil }

    /// The model that answers. Order: ASSISTANT_DEEP_MODEL in the process environment (so a probe can
    /// compare models), then the Settings picker, then ASSISTANT_DEEP_MODEL in ~/.zshrc, then sarvam-105b.
    static var answerModel: String {
        let env = ProcessInfo.processInfo.environment["ASSISTANT_DEEP_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
        let picked = env ?? UserDefaults.standard.string(forKey: "answerModel") ?? Keys.setting("ASSISTANT_DEEP_MODEL", default: "sarvam-105b")
        return picked.hasPrefix("gemini") && !available ? "sarvam-105b" : picked
    }

    /// The model for asks that act on the page (agent route with controls to press). Picking a control
    /// is where sarvam-105b failed (3 of 18 right vs 14 of 18 for Gemini 3.5 Flash, 22 Oct), so actions
    /// go to Gemini when it's set up, while talk keeps the faster answer model.
    /// ASSISTANT_ACTION_MODEL overrides; "same" uses the answer model for everything.
    static var actionModel: String {
        let picked = Keys.setting("ASSISTANT_ACTION_MODEL", default: "gemini-3.5-flash")
        if picked == "same" || !available { return answerModel }
        return picked
    }

    static func stream(model: String, messages: [[String: Any]], tools: [[String: Any]]?, toolChoice: String,
                       reasoning: String?, maxTokens: Int, temperature: Double?, json: Bool) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard let key = Keys.vertex, let project else {
                        throw APIError(status: 401, body: "Add a Google Cloud key and project ID in Settings → API Keys.")
                    }
                    let loc = location
                    let host = loc == "global" ? "aiplatform.googleapis.com" : "\(loc)-aiplatform.googleapis.com"
                    var req = URLRequest(url: URL(string: "https://\(host)/v1/projects/\(project)/locations/\(loc)/publishers/google/models/\(model):streamGenerateContent?alt=sse")!)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 60
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body(messages: messages, tools: tools, toolChoice: toolChoice,
                                                                                   reasoning: reasoning, maxTokens: maxTokens,
                                                                                   temperature: temperature, json: json))
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 2000 { break } }
                        throw APIError(status: status, body: text)
                    }
                    var callIndex = 0
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:"),
                              let d = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let cand = (obj["candidates"] as? [[String: Any]])?.first else { continue }
                        for part in ((cand["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? [] {
                            if let fc = part["functionCall"] as? [String: Any], let name = fc["name"] as? String {
                                // Gemini sends a call whole. Its thought signature must come back with the call on
                                // the follow-up turn, so it rides in the call id (the only field that round-trips).
                                let args = (try? JSONSerialization.data(withJSONObject: fc["args"] ?? [String: Any]()))
                                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                let id = "g\(callIndex)" + ((part["thoughtSignature"] as? String).map { "|\($0)" } ?? "")
                                cont.yield(.toolCallDelta(index: callIndex, id: id, name: name, arguments: args))
                                callIndex += 1
                            } else if let t = part["text"] as? String, !t.isEmpty {
                                cont.yield(part["thought"] as? Bool == true ? .reasoning(t) : .text(t))
                            }
                        }
                        if let f = cand["finishReason"] as? String {
                            cont.yield(.finished(callIndex > 0 ? "tool_calls" : f.lowercased()))
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

    // MARK: - OpenAI-style request → Gemini request

    static func body(messages: [[String: Any]], tools: [[String: Any]]?, toolChoice: String, reasoning: String?,
                     maxTokens: Int, temperature: Double?, json: Bool) -> [String: Any] {
        var system: [String] = []
        var contents: [[String: Any]] = []
        var names: [String: String] = [:]   // tool_call_id → function name, for functionResponse
        func add(_ role: String, _ parts: [[String: Any]]) {
            guard !parts.isEmpty else { return }
            // Gemini wants turns to alternate; merge neighbours with the same role (e.g. several tool results).
            if let last = contents.last, last["role"] as? String == role {
                contents[contents.count - 1]["parts"] = (last["parts"] as? [[String: Any]] ?? []) + parts
            } else {
                contents.append(["role": role, "parts": parts])
            }
        }
        for m in messages {
            let role = m["role"] as? String ?? "user"
            switch role {
            case "system":
                if let s = m["content"] as? String { system.append(s) }
            case "assistant":
                var parts: [[String: Any]] = []
                if let s = m["content"] as? String, !s.isEmpty { parts.append(["text": s]) }
                for tc in (m["tool_calls"] as? [[String: Any]]) ?? [] {
                    let fn = tc["function"] as? [String: Any] ?? [:]
                    let id = tc["id"] as? String ?? ""
                    let name = fn["name"] as? String ?? ""
                    names[id] = name
                    let args = (fn["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? [String: Any]()
                    var part: [String: Any] = ["functionCall": ["name": name, "args": args]]
                    if let bar = id.firstIndex(of: "|") { part["thoughtSignature"] = String(id[id.index(after: bar)...]) }
                    parts.append(part)
                }
                add("model", parts)
            case "tool":
                let id = m["tool_call_id"] as? String ?? ""
                add("user", [["functionResponse": ["name": names[id] ?? "tool", "response": ["result": m["content"] as? String ?? ""]]]])
            default:
                add("user", userParts(m["content"]))
            }
        }
        var gen: [String: Any] = ["maxOutputTokens": maxTokens,
                                  "thinkingConfig": ["thinkingLevel": reasoning == nil ? "MINIMAL" : reasoning!.uppercased()]]
        if let temperature { gen["temperature"] = temperature }
        if json { gen["responseMimeType"] = "application/json" }
        var out: [String: Any] = ["contents": contents, "generationConfig": gen]
        if !system.isEmpty { out["systemInstruction"] = ["parts": [["text": system.joined(separator: "\n\n")]]] }
        if let tools, !tools.isEmpty {
            let decls = tools.compactMap { $0["function"] as? [String: Any] }.map { f -> [String: Any] in
                ["name": f["name"] ?? "", "description": f["description"] ?? "", "parametersJsonSchema": f["parameters"] ?? ["type": "object"]]
            }
            out["tools"] = [["functionDeclarations": decls]]
            out["toolConfig"] = ["functionCallingConfig": ["mode": toolChoice == "none" ? "NONE" : "AUTO"]]
        }
        return out
    }

    private static func userParts(_ content: Any?) -> [[String: Any]] {
        if let s = content as? String { return s.isEmpty ? [] : [["text": s]] }
        return ((content as? [[String: Any]]) ?? []).compactMap { p in
            if let t = p["text"] as? String { return ["text": t] }
            // data:image/jpeg;base64,....
            if let url = (p["image_url"] as? [String: Any])?["url"] as? String, url.hasPrefix("data:"),
               let comma = url.firstIndex(of: ","), let semi = url.firstIndex(of: ";") {
                return ["inlineData": ["mimeType": String(url[url.index(url.startIndex, offsetBy: 5)..<semi]),
                                       "data": String(url[url.index(after: comma)...])]]
            }
            return nil
        }
    }
}
