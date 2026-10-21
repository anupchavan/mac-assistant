import Foundation

/// Mistral: Voxtral realtime STT, Voxtral TTS, and chat (Small for screenshots, Medium for text).
/// Wire formats are from mistralai/client-python (realtime/connection.py, models/speech*.py).
enum Mistral {
    static let base = URL(string: "https://api.mistral.ai/v1")!

    static func key() throws -> String {
        guard let k = Keys.mistral else { throw MissingKey.mistral }
        return k
    }

    /// Voxtral reports ISO codes ("hi", "en") or nothing; the rest of the app speaks Sarvam's "hi-IN" style.
    /// With no code, Devanagari in the transcript means Hindi (Voxtral writes Hinglish's Hindi words in Devanagari).
    static func languageTag(_ code: String?, text: String) -> String {
        let c = (code ?? "").lowercased().prefix(2)
        if c.isEmpty { return text.range(of: #"[\x{0900}-\x{097F}]"#, options: .regularExpression) != nil ? "hi-IN" : "en-IN" }
        return Sarvam.ttsLanguages.first { $0.hasPrefix(c) } ?? String(c)
    }
}

// MARK: - Speech to text (Voxtral realtime WebSocket; REST fallback)

final class MistralSTT: NSObject, SpeechToText, URLSessionWebSocketDelegate {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String, String?) -> Void)?
    var onError: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var audio = Data()                 // everything sent, for the REST fallback
    private var text = ""
    private var language: String?
    private var failed = false
    private var opened = false
    private var outbox: [[String: Any]] = []   // sent before the socket opened; flushed in order on open
    private var finalWaiters: [CheckedContinuation<(String, String?), Never>] = []
    private let queue = DispatchQueue(label: "mistral-stt")
    static var debug = false

    func connect() {
        guard let key = Keys.mistral else { failed = true; onError?(MissingKey.mistral.localizedDescription); return }
        var c = URLComponents(string: "wss://api.mistral.ai/v1/audio/transcriptions/realtime")!
        c.queryItems = [.init(name: "model", value: Keys.setting("MISTRAL_STT_MODEL", default: "voxtral-mini-transcribe-realtime-3-0"))]
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        task = s.webSocketTask(with: req)
        task?.resume()
        // Lower delay = earlier partials but less context per word. The final after flush doesn't wait for it.
        let delay = Int(Keys.setting("MISTRAL_STT_DELAY_MS", default: "240")) ?? 240
        queue.async { [self] in
            sendJSON(["type": "session.update", "session": ["audio_format": ["encoding": "pcm_s16le", "sample_rate": 16000],
                                                            "target_streaming_delay_ms": delay]])
        }
        receive()
    }

    func send(_ chunk: Data) {
        queue.async { [self] in
            audio.append(chunk)
            guard !failed, task != nil else { return }
            sendJSON(["type": "input_audio.append", "audio": chunk.base64EncodedString()])
        }
    }

    func finish(timeout: TimeInterval) async -> (String, String?) {
        for _ in 0..<15 where !queue.sync(execute: { opened || failed }) { try? await Task.sleep(nanoseconds: 100_000_000) }
        queue.sync {
            if !opened { failed = true }
            if !failed { sendJSON(["type": "input_audio.flush"]); sendJSON(["type": "input_audio.end"]) }
        }
        if queue.sync(execute: { failed }) { return await restFallback() }
        let result: (String, String?) = await withCheckedContinuation { cont in
            queue.async { [self] in
                if failed { cont.resume(returning: ("", nil)); return }
                finalWaiters.append(cont)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in resumeWaiters() }
            }
        }
        close()
        if !result.0.isEmpty { return result }
        return await restFallback()
    }

    func close() {
        queue.async { [self] in
            task?.cancel(with: .normalClosure, reason: nil)
            task = nil
            resumeWaiters()
        }
        session?.finishTasksAndInvalidate()
    }

    /// Call on `queue`.
    private func resumeWaiters() {
        let waiters = finalWaiters; finalWaiters.removeAll()
        let t = text.trimmingCharacters(in: .whitespaces)
        for w in waiters { w.resume(returning: (t, t.isEmpty ? nil : Mistral.languageTag(language, text: t))) }
    }

    /// Call on `queue`.
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
                if self.queue.sync(execute: { self.task != nil }) { self.markFailed(err.localizedDescription) }
            case .success(let msg):
                if case let .string(s) = msg { self.handle(s) }
                self.receive()
            }
        }
    }

    private func handle(_ s: String) {
        if Self.debug { Log.info("stt ← \(s.prefix(240))") }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { return }
        switch obj["type"] as? String ?? "" {
        case "transcription.text.delta":
            let delta = obj["text"] as? String ?? ""
            queue.async { [self] in
                text += delta
                let full = text.trimmingCharacters(in: .whitespaces)
                DispatchQueue.main.async { self.onPartial?(full) }
            }
        case "transcription.language":
            queue.async { self.language = obj["audio_language"] as? String }
        case "transcription.done":
            queue.async { [self] in
                if let t = obj["text"] as? String, !t.isEmpty { text = t }
                if let l = obj["language"] as? String { language = l }
                let full = text.trimmingCharacters(in: .whitespaces)
                let lang = Mistral.languageTag(language, text: full)
                resumeWaiters()
                DispatchQueue.main.async { self.onPartial?(full); self.onFinal?(full, lang) }
            }
        case "error":
            let detail = obj["error"] as? [String: Any]
            let message = (detail?["message"] as? String) ?? (detail?["message"]).map { "\($0)" } ?? "STT error"
            Log.error("stt error: \(message)")
            markFailed(message)
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
        queue.async { [self] in
            opened = true
            let pending = outbox; outbox.removeAll()
            for m in pending { sendJSON(m) }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if closeCode != .normalClosure { markFailed("closed \(closeCode.rawValue) \(reason.flatMap { String(data: $0, encoding: .utf8) } ?? "")") }
    }

    private func restFallback() async -> (String, String?) {
        let pcm = queue.sync { audio }
        guard pcm.count > 3200 else { return ("", nil) }
        do { return try await MistralSTT.transcribe(wav: Microphone.wav(pcm)) } catch {
            DispatchQueue.main.async { self.onError?(error.localizedDescription) }
            return ("", nil)
        }
    }

    static func transcribe(wav: Data) async throws -> (String, String?) {
        var req = URLRequest(url: Mistral.base.appendingPathComponent("audio/transcriptions"))
        req.httpMethod = "POST"
        let boundary = "b\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(try Mistral.key())", forHTTPHeaderField: "Authorization")
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(Keys.setting("MISTRAL_STT_REST_MODEL", default: "voxtral-mini-transcribe-3-0"))\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError(status: status, body: String(data: data, encoding: .utf8) ?? "", provider: .mistral) }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let text = obj["text"] as? String ?? ""
        return (text, Mistral.languageTag(obj["language"] as? String, text: text))
    }
}

// MARK: - Text to speech (Voxtral TTS, one streaming request at a time)

/// There is no TTS socket: each request is one piece of text. Sentences that arrive while a request is
/// streaming wait and go together in the next one, so audio stays in order and prosody spans sentences.
/// No speed setting exists; it plays at the voice's natural pace.
final class MistralTTS: TextToSpeech {
    var onAudio: ((Data) -> Void)?
    var onFinal: (() -> Void)?
    var onError: ((String) -> Void)?
    private var pending: [String] = []
    private var flushed = false
    private var running: Task<Void, Never>?
    private var closed = false
    private let lock = NSLock()

    func connect() throws { _ = try Mistral.key() }

    func speak(_ text: String) {
        lock.lock(); pending.append(text); lock.unlock()
        pump()
    }

    func flush() {
        lock.lock(); flushed = true; lock.unlock()
        pump()
    }

    func close() {
        lock.lock(); closed = true; pending.removeAll(); let r = running; lock.unlock()
        r?.cancel()
    }

    private func pump() {
        lock.lock()
        guard !closed, running == nil else { lock.unlock(); return }
        if pending.isEmpty {
            let done = flushed
            lock.unlock()
            if done { DispatchQueue.main.async { self.onFinal?() } }
            return
        }
        let text = pending.joined(separator: " ")
        pending.removeAll()
        running = Task { [weak self] in
            await self?.stream(text)
            self?.streamEnded()
        }
        lock.unlock()
    }

    private func streamEnded() {
        lock.lock(); running = nil; lock.unlock()
        pump()
    }

    private func stream(_ text: String) async {
        do {
            var req = URLRequest(url: Mistral.base.appendingPathComponent("audio/speech"))
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(try Mistral.key())", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": Keys.setting("MISTRAL_TTS_MODEL", default: "voxtral-mini-tts-3-0"),
                "input": text,
                // Himanshu, a Hindi preset that also speaks English (Voxtral voices are cross-lingual).
                "voice_id": Keys.setting("MISTRAL_TTS_VOICE", default: "01a155a0-3da4-72d1-90d6-848eddd4765c"),
                "response_format": "pcm", "stream": true,
            ] as [String: Any])
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                var body = ""
                for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
                throw APIError(status: status, body: body, provider: .mistral)
            }
            var carry = Data()   // float32 samples can straddle chunks
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:"),
                      let obj = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String: Any],
                      obj["type"] as? String == "speech.audio.delta",
                      let b64 = obj["audio_data"] as? String, let raw = Data(base64Encoded: b64) else { continue }
                carry.append(raw)
                let whole = carry.count / 4 * 4
                if whole > 0 { onAudio?(Self.int16(fromFloat32: carry.prefix(whole))); carry = Data(carry.dropFirst(whole)) }
            }
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            Log.error("tts error: \(error.localizedDescription)")
            DispatchQueue.main.async { self.onError?(error.localizedDescription) }
        }
    }

    /// `pcm` from Voxtral is 32-bit float little-endian at 24 kHz; the player takes 16-bit.
    static func int16(fromFloat32 data: Data) -> Data {
        let n = data.count / 4
        var out = Data(count: n * 2)
        data.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                let s = src.bindMemory(to: UInt32.self), d = dst.bindMemory(to: Int16.self)
                for i in 0..<n {
                    let f = Float(bitPattern: UInt32(littleEndian: s[i]))
                    d[i] = Int16(max(-1, min(1, f)) * 32767).littleEndian
                }
            }
        }
        return out
    }
}

// MARK: - Chat completions (OpenAI-compatible SSE)

enum MistralChat {
    /// `reasoning` nil turns thinking off ("none"); Sarvam's "high" maps straight across.
    static func stream(model: String, messages: [[String: Any]], tools: [[String: Any]]? = nil, toolChoice: String = "auto",
                       reasoning: String? = nil, maxTokens: Int, temperature: Double? = nil, json: Bool = false) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = URLRequest(url: Mistral.base.appendingPathComponent("chat/completions"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 60
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(try Mistral.key())", forHTTPHeaderField: "Authorization")
                    var body: [String: Any] = ["model": model, "messages": messages.map(adapt), "stream": true, "max_tokens": maxTokens,
                                               "reasoning_effort": reasoning ?? "none"]
                    if let tools, !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = toolChoice }
                    if let temperature { body["temperature"] = temperature }
                    if json { body["response_format"] = ["type": "json_object"] }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 2000 { break } }
                        throw APIError(status: status, body: text, provider: .mistral)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
                              let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
                        let delta = choice["delta"] as? [String: Any] ?? [:]
                        // Content is a string, or a list of chunks when the model thinks ({"type":"thinking"} / {"type":"text"}).
                        if let c = delta["content"] as? String, !c.isEmpty { cont.yield(.text(c)) }
                        for chunk in (delta["content"] as? [[String: Any]]) ?? [] {
                            if chunk["type"] as? String == "text", let t = chunk["text"] as? String, !t.isEmpty { cont.yield(.text(t)) }
                            if chunk["type"] as? String == "thinking" { cont.yield(.reasoning("…")) }
                        }
                        for (i, tc) in ((delta["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
                            let fn = tc["function"] as? [String: Any]
                            // Mistral sends arguments as a string, sometimes as an object.
                            let args = fn?["arguments"] as? String
                                ?? (fn?["arguments"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) }
                            cont.yield(.toolCallDelta(index: tc["index"] as? Int ?? i, id: tc["id"] as? String, name: fn?["name"] as? String, arguments: args))
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

    /// The app builds OpenAI-shaped messages; Mistral wants `image_url` as a plain string.
    private static func adapt(_ m: [String: Any]) -> [String: Any] {
        guard let parts = m["content"] as? [[String: Any]] else { return m }
        var out = m
        out["content"] = parts.map { p -> [String: Any] in
            guard p["type"] as? String == "image_url", let u = (p["image_url"] as? [String: Any])?["url"] as? String else { return p }
            return ["type": "image_url", "image_url": u]
        }
        return out
    }
}
