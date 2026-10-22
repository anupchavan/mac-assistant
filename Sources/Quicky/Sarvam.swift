import Foundation

struct APIError: LocalizedError {
    enum Provider { case sarvam, openAI, elevenLabs }
    let status: Int
    let body: String
    var provider: Provider = .sarvam

    init(status: Int, body: String, provider: Provider = .sarvam) {
        self.status = status; self.body = body; self.provider = provider
        if status == 401 { Keys.reload() }      // a fixed key in ~/.zshrc works on the next try
    }

    /// One plain sentence for the panel. Never the raw body, never any part of a key.
    var errorDescription: String? {
        let detail = sanitizedMessage.isEmpty ? "." : ": \(sanitizedMessage)"
        switch (provider, status) {
        case (.openAI, 401): return "Your OpenAI key was refused. Paste a working one in Settings (⌘, from the menu-bar ?)."
        case (.openAI, 403), (.openAI, 404): return "Your OpenAI account can't use the computer-use model yet."
        case (.openAI, 402), (.openAI, 429): return "OpenAI rate limit or no credits."
        case (.sarvam, 401), (.sarvam, 403): return "Your Sarvam key was refused. Paste a working one in Settings (⌘, from the menu-bar ?)."
        case (.sarvam, _) where isOutOfCredits: return "Sarvam rate limit or no credits. Add credits and press ↵ to retry."
        case (_, 500...): return "\(name) is having trouble (\(status)). Press ↵ to retry."
        default: return "\(name) returned an error (\(status))\(detail)"
        }
    }

    private var name: String {
        switch provider { case .sarvam: return "Sarvam"; case .openAI: return "OpenAI"; case .elevenLabs: return "ElevenLabs" }
    }

    /// The server's message, short and with anything key-like removed. Safe for the panel and the log.
    var sanitizedMessage: String {
        var m = serverMessage
        for pattern in [#"sk-[A-Za-z0-9_\-\*]+"#, #"\*{3,}[A-Za-z0-9_\-]*"#, #"[A-Za-z0-9_\-]{24,}"#, #"[{}\[\]"]"#] {
            m = m.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        m = m.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return m.count > 80 ? String(m.prefix(79)) + "…" : m
    }
    /// `error.message` from the JSON body when there is one, else the raw body.
    var serverMessage: String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let msg = (obj?["error"] as? [String: Any])?["message"] as? String ?? obj?["message"] as? String
        return (msg ?? body).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var isAuthOrAccess: Bool { status == 401 || status == 403 }
    var isOutOfCredits: Bool { status == 402 || status == 429 || body.lowercased().contains("credit") || body.lowercased().contains("quota") }
}

enum MissingKey: LocalizedError {
    case sarvam, openAI, elevenLabs
    var errorDescription: String? {
        switch self {
        case .sarvam: return "No Sarvam key found. Add export SARVAM_API_KEY=… to ~/.zshrc."
        case .openAI: return "No OpenAI key found. Add export OPENAI_API_KEY=… to ~/.zshrc."
        case .elevenLabs: return "No ElevenLabs key found. Add export ELEVENLABS_API_KEY=… to ~/.zshrc."
        }
    }
}

enum Sarvam {
    static let base = URL(string: "https://api.sarvam.ai")!
    static let ttsLanguages: Set<String> = ["bn-IN", "en-IN", "gu-IN", "hi-IN", "kn-IN", "ml-IN", "mr-IN", "od-IN", "pa-IN", "ta-IN", "te-IN"]

    static func key() throws -> String {
        guard let k = Keys.sarvam else { throw MissingKey.sarvam }
        return k
    }

    static func ttsLanguage(for detected: String?) -> String {
        guard let d = detected else { return "en-IN" }
        if ttsLanguages.contains(d) { return d }
        if d.hasPrefix("en") { return "en-IN" }
        let prefix = d.prefix(2)
        return ttsLanguages.first { $0.hasPrefix(prefix) } ?? "en-IN"
    }
}

// MARK: - Speech to text (realtime WebSocket, manual endpointing; REST fallback)

final class SarvamSTT: NSObject, URLSessionWebSocketDelegate {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String, String?) -> Void)?
    var onError: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private(set) var audio = Data()           // everything sent, for the REST fallback
    private var finals: [String] = []
    private var language: String?
    private var failed = false
    private var finalWaiters: [CheckedContinuation<(String, String?), Never>] = []
    private var lastPartial = ""
    private var speechStarted = false
    private var opened = false
    private var outbox: [[String: Any]] = []     // sent before the socket opened; flushed in order on open
    private let queue = DispatchQueue(label: "stt")

    func connect() {
        guard let key = Keys.sarvam else { failed = true; onError?(MissingKey.sarvam.localizedDescription); return }
        let model = Keys.setting("ASSISTANT_STT_MODEL", default: "saaras:v4")
        var c = URLComponents(string: "wss://api.sarvam.ai/speech-to-text-realtime/ws")!
        c.queryItems = [
            .init(name: "language_code", value: "auto"),
            .init(name: "model", value: model),
            .init(name: "mode", value: Keys.setting("ASSISTANT_STT_MODE", default: "transcribe")),
            .init(name: "stream_type", value: "fast"),
            .init(name: "endpointing", value: "manual"),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
        ]
        var req = URLRequest(url: c.url!)
        req.setValue(key, forHTTPHeaderField: "Api-Subscription-Key")
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        let t = s.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
    }

    func send(_ chunk: Data) {
        queue.async { [self] in
            audio.append(chunk)
            guard !failed, task != nil else { return }
            if !speechStarted { speechStarted = true; sendJSON(["event": "speech_start"]) }
            sendJSON(["event": "audio_input", "audio": chunk.base64EncodedString()])
        }
    }

    /// End of the user's turn: ask for the final transcript and wait for it (or fall back to REST).
    func finish(timeout: TimeInterval = 3) async -> (String, String?) {
        // Give a slow handshake a moment; after that, the REST fallback has all the audio anyway.
        for _ in 0..<15 where !queue.sync(execute: { opened || failed }) { try? await Task.sleep(nanoseconds: 100_000_000) }
        queue.sync {
            if !opened { failed = true }
            if !failed { sendJSON(["event": "speech_end"]) }
        }
        if queue.sync(execute: { failed }) { return await restFallback() }
        let result: (String, String?) = await withCheckedContinuation { cont in
            queue.async { [self] in
                if failed { cont.resume(returning: ("", nil)); return }
                finalWaiters.append(cont)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    let waiters = finalWaiters; finalWaiters.removeAll()
                    for w in waiters { w.resume(returning: (lastPartial, language)) }
                }
            }
        }
        close()
        if !result.0.isEmpty { return result }
        return await restFallback()
    }

    func close() {
        queue.async { [self] in
            if let task { sendJSON(["event": "end"]); task.cancel(with: .normalClosure, reason: nil) }
            task = nil
            let waiters = finalWaiters; finalWaiters.removeAll()
            for w in waiters { w.resume(returning: (finals.joined(separator: " "), language)) }
        }
        session?.finishTasksAndInvalidate()
    }

    /// Call on `queue`. The mic starts streaming at fn-down, before the handshake finishes; sending on an
    /// unopened socket fails with "Socket is not connected", so those messages wait in the outbox.
    private func sendJSON(_ obj: [String: Any]) {
        guard opened else { outbox.append(obj); return }
        guard let task, let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { [weak self] err in
            if let err { self?.markFailed("send: \(err.localizedDescription)") }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                // After we close the socket ourselves, the pending receive fails too; that's not a failure.
                if self.queue.sync(execute: { self.task != nil }) { self.markFailed(err.localizedDescription) }
            case .success(let msg):
                if case let .string(s) = msg { self.handle(s) }
                self.receive()
            }
        }
    }

    static var debug = false

    private func handle(_ s: String) {
        if Self.debug { Log.info("stt ← \(s.prefix(240))") }
        guard let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let event = obj["event"] as? String ?? obj["type"] as? String ?? ""
        let payload = (obj["data"] as? [String: Any]) ?? obj
        switch event {
        case "transcript.partial":
            let text = payload["text"] as? String ?? ""
            queue.async { self.lastPartial = (self.finals + [text]).joined(separator: " ") }
            let full = queue.sync { lastPartial }
            DispatchQueue.main.async { self.onPartial?(full) }
        case "transcript.final":
            let text = payload["text"] as? String ?? ""
            let lang = payload["language"] as? String
            queue.async {
                if !text.isEmpty { self.finals.append(text) }
                if let lang { self.language = lang }
                self.lastPartial = self.finals.joined(separator: " ")
                let full = self.lastPartial
                let waiters = self.finalWaiters; self.finalWaiters.removeAll()
                for w in waiters { w.resume(returning: (full, self.language)) }
                DispatchQueue.main.async { self.onPartial?(full); self.onFinal?(full, self.language) }
            }
        case "error":
            let fatal = payload["is_fatal"] as? Bool ?? false
            let message = payload["message"] as? String ?? "STT error"
            Log.error("stt error: \(message)")
            if fatal { markFailed(message) }
        default:
            break
        }
    }

    private func markFailed(_ why: String) {
        queue.async { [self] in
            guard !failed else { return }
            failed = true
            Log.error("stt socket failed (\(why)); will use REST")
            let waiters = finalWaiters; finalWaiters.removeAll()
            for w in waiters { w.resume(returning: ("", nil)) }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        if Self.debug { Log.info("stt socket open") }
        queue.async { [self] in
            opened = true
            let pending = outbox; outbox.removeAll()
            for m in pending { sendJSON(m) }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let r = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if closeCode != .normalClosure { markFailed("closed \(closeCode.rawValue) \(r)") }
    }

    /// One-shot REST transcription of everything recorded (used if the socket is refused).
    private func restFallback() async -> (String, String?) {
        let pcm = queue.sync { audio }
        guard pcm.count > 3200 else { return ("", nil) }
        do {
            let r = try await SarvamSTT.transcribe(wav: Microphone.wav(pcm))
            return r
        } catch {
            DispatchQueue.main.async { self.onError?(error.localizedDescription) }
            return ("", nil)
        }
    }

    static func transcribe(wav: Data) async throws -> (String, String?) {
        let key = try Sarvam.key()
        var req = URLRequest(url: Sarvam.base.appendingPathComponent("speech-to-text"))
        req.httpMethod = "POST"
        let boundary = "b\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "api-subscription-key")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", Keys.setting("ASSISTANT_STT_REST_MODEL", default: "saaras:v3"))
        field("mode", "transcribe")
        field("language_code", "unknown")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError(status: status, body: String(data: data, encoding: .utf8) ?? "") }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (obj["transcript"] as? String ?? "", obj["language_code"] as? String)
    }
}

// MARK: - Text to speech (Bulbul WebSocket)

final class SarvamTTS: NSObject, URLSessionWebSocketDelegate {
    /// Settings → Voice speed, else ASSISTANT_TTS_PACE, else 1.0 (Bulbul's natural speed).
    static var pace: Double {
        if let v = UserDefaults.standard.object(forKey: "ttsPace") as? Double { return v }
        return Double(Keys.setting("ASSISTANT_TTS_PACE", default: "1.0")) ?? 1.0
    }
    var onAudio: ((Data) -> Void)?
    var onFinal: (() -> Void)?
    var onError: ((String) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    let language: String
    let sampleRate: Int

    init(language: String, sampleRate: Int = 22050) {
        self.language = language
        self.sampleRate = sampleRate
    }

    func connect() throws {
        let key = try Sarvam.key()
        let model = Keys.setting("ASSISTANT_TTS_MODEL", default: "bulbul:v4-flash")
        var c = URLComponents(string: "wss://api.sarvam.ai/text-to-speech/ws")!
        c.queryItems = [.init(name: "model", value: model), .init(name: "send_completion_event", value: "true")]
        var req = URLRequest(url: c.url!)
        req.setValue(key, forHTTPHeaderField: "Api-Subscription-Key")
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        task = s.webSocketTask(with: req)
        task?.resume()
        send(["type": "config", "data": [
            "language_code": language,
            "speaker": Keys.setting("ASSISTANT_TTS_SPEAKER", default: "sarika_hi_conversation"),   // v4 speakers differ from v3's
            "pace": SarvamTTS.pace,
            "speech_sample_rate": sampleRate,
            "output_audio_codec": "linear16",
            "min_buffer_size": 30,
            "max_chunk_length": 150,
        ] as [String: Any]])
        receive()
    }

    func speak(_ text: String) {
        // Bulbul recommends < 500 characters per message.
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = rest.prefix(450)
            send(["type": "text", "data": ["text": String(piece)]])
            rest = rest.dropFirst(piece.count)
        }
    }

    func flush() { send(["type": "flush"]) }

    /// There is no cancel message: stopping closes the socket.
    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.finishTasksAndInvalidate()
    }

    private func send(_ obj: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { [weak self] err in
            if let err { DispatchQueue.main.async { self?.onError?(err.localizedDescription) } }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                if self.task != nil { DispatchQueue.main.async { self.onError?(err.localizedDescription) } }
            case .success(let msg):
                if case let .string(s) = msg { self.handle(s) }
                if self.task != nil { self.receive() }
            }
        }
    }

    private func handle(_ s: String) {
        guard let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""
        let payload = obj["data"] as? [String: Any] ?? [:]
        if type == "audio", let b64 = payload["audio"] as? String, let pcm = Data(base64Encoded: b64) {
            onAudio?(pcm)
        } else if type == "event" || payload["event_type"] != nil {
            if (payload["event_type"] as? String) == "final" { DispatchQueue.main.async { self.onFinal?() } }
        } else if type == "error" {
            let m = payload["message"] as? String ?? "TTS error"
            Log.error("tts error: \(m)")
            DispatchQueue.main.async { self.onError?(m) }
        }
    }
}

// MARK: - Chat completions (OpenAI-compatible SSE; v1 for sarvam-105b, v2 for gemma4 with images)

enum ChatEvent {
    case reasoning(String)
    case text(String)
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String?)
    case finished(String?)
}

enum SarvamChat {
    enum Version: String { case v1, v2 }

    /// `toolChoice` "none" is for the reply after a tool result: /v1 rejects tool messages unless tools are sent too.
    /// A "gemini-…" model goes to Vertex in Mumbai. If Gemini fails before saying anything (bad key, quota,
    /// outage), the same request goes to sarvam-105b so a turn never dies on the optional model.
    static func stream(model: String, version: Version, messages: [[String: Any]], tools: [[String: Any]]? = nil,
                       toolChoice: String = "auto", reasoning: String? = nil, maxTokens: Int, temperature: Double? = nil,
                       json: Bool = false) -> AsyncThrowingStream<ChatEvent, Error> {
        guard Gemini.isGemini(model) else {
            return sarvamStream(model: model, version: version, messages: messages, tools: tools, toolChoice: toolChoice,
                                reasoning: reasoning, maxTokens: maxTokens, temperature: temperature, json: json)
        }
        return AsyncThrowingStream { cont in
            let task = Task {
                var said = false
                do {
                    for try await e in Gemini.stream(model: model, messages: messages, tools: tools, toolChoice: toolChoice,
                                                     reasoning: reasoning, maxTokens: maxTokens, temperature: temperature, json: json) {
                        said = true
                        cont.yield(e)
                    }
                    cont.finish()
                } catch {
                    guard !said, !(error is CancellationError) else { cont.finish(throwing: error); return }
                    // A screenshot ask falls back to gemma4 (the only Sarvam model that sees images).
                    let hasImage = messages.contains { (($0["content"] as? [[String: Any]]) ?? []).contains { $0["image_url"] != nil } }
                    let (fbModel, fbVersion) = hasImage ? (Keys.setting("ASSISTANT_VISION_MODEL", default: "gemma4"), Version.v2) : ("sarvam-105b", Version.v1)
                    Log.error("\(model) failed (\((error as? APIError).map { "\($0.status): \($0.sanitizedMessage)" } ?? error.localizedDescription)); answering with \(fbModel)")
                    do {
                        for try await e in sarvamStream(model: fbModel, version: fbVersion, messages: messages, tools: tools, toolChoice: toolChoice,
                                                        reasoning: reasoning, maxTokens: maxTokens, temperature: temperature, json: json) {
                            cont.yield(e)
                        }
                        cont.finish()
                    } catch { cont.finish(throwing: error) }
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private static func sarvamStream(model: String, version: Version, messages: [[String: Any]], tools: [[String: Any]]?,
                                     toolChoice: String, reasoning: String?, maxTokens: Int, temperature: Double?,
                                     json: Bool) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let key = try Sarvam.key()
                    var req = URLRequest(url: Sarvam.base.appendingPathComponent("\(version.rawValue)/chat/completions"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 60
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(key, forHTTPHeaderField: "api-subscription-key")
                    var body: [String: Any] = ["model": model, "messages": messages, "stream": true, "max_tokens": maxTokens]
                    if let tools, !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = toolChoice }
                    // nil sends an explicit null, which turns thinking off; omitting the field leaves it on (even "low" thinks for ~1k tokens).
                    body["reasoning_effort"] = reasoning ?? NSNull()
                    if let temperature { body["temperature"] = temperature }
                    if json { body["response_format"] = ["type": "json_object"] }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 2000 { break } }
                        throw APIError(status: status, body: text)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
                        let delta = choice["delta"] as? [String: Any] ?? [:]
                        if let r = (delta["reasoning"] ?? delta["reasoning_content"]) as? String, !r.isEmpty { cont.yield(.reasoning(r)) }
                        if let c = delta["content"] as? String, !c.isEmpty { cont.yield(.text(c)) }
                        for tc in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                            let fn = tc["function"] as? [String: Any]
                            cont.yield(.toolCallDelta(index: tc["index"] as? Int ?? 0, id: tc["id"] as? String,
                                                      name: fn?["name"] as? String, arguments: fn?["arguments"] as? String))
                        }
                        if let f = choice["finish_reason"] as? String { cont.yield(.finished(f)) }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming convenience: collect the whole text.
    static func complete(model: String, version: Version = .v1, messages: [[String: Any]], reasoning: String? = nil,
                         maxTokens: Int, json: Bool = false) async throws -> String {
        var out = ""
        for try await e in stream(model: model, version: version, messages: messages, reasoning: reasoning, maxTokens: maxTokens, json: json) {
            if case let .text(t) = e { out += t }
        }
        return out
    }
}
