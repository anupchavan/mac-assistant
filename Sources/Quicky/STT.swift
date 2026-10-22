import Foundation

/// A realtime speech-to-text socket. The mic streams 16 kHz mono linear16 into `send` from fn-down;
/// `finish` ends the turn and returns (transcript, language code).
protocol SpeechToText: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func connect()
    func send(_ chunk: Data)
    func finish(timeout: TimeInterval) async -> (String, String?)
    func close()
}

extension SarvamSTT: SpeechToText {}

enum STT {
    enum Provider: String { case sarvam, deepgram }

    /// Settings → Speech recognition, else ASSISTANT_STT_PROVIDER, else Deepgram when its key is set.
    /// Deepgram without a key quietly means Sarvam.
    static var chosen: Provider {
        if let v = UserDefaults.standard.string(forKey: "sttProvider"), let p = Provider(rawValue: v) { return p }
        if let p = Provider(rawValue: Keys.setting("ASSISTANT_STT_PROVIDER", default: "").lowercased()) { return p }
        return Keys.deepgram != nil ? .deepgram : .sarvam
    }

    static var provider: Provider { chosen == .deepgram && Keys.deepgram == nil ? .sarvam : chosen }

    static func make(_ p: Provider = provider) -> SpeechToText {
        switch p {
        case .sarvam: return SarvamSTT()
        case .deepgram: return DeepgramSTT()
        }
    }
}

// MARK: - Deepgram Nova-3 (India region, Hyderabad)

/// Deepgram streaming over `wss://api.in.deepgram.com/v1/listen`. Raw PCM goes up as binary frames;
/// at the end of the turn we send `Finalize`, and the result marked `from_finalize` is the last one.
/// If the socket fails, the recorded audio goes to Sarvam's REST endpoint instead.
final class DeepgramSTT: NSObject, SpeechToText, URLSessionWebSocketDelegate {
    var onPartial: ((String) -> Void)?
    var onError: ((String) -> Void)?
    static var debug = false

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var audio = Data()
    private var finals: [String] = []
    private var interim = ""
    private var language: String?
    private var opened = false
    private var failed = false
    private var finalizing = false
    private var done = false
    private var outbox: [Data] = []
    private var finalWaiters: [CheckedContinuation<(String, String?), Never>] = []
    private let queue = DispatchQueue(label: "stt.deepgram")
    /// When Deepgram fails mid-turn, a Sarvam socket takes over with everything recorded so far,
    /// so the turn still streams instead of waiting on a REST upload at the end.
    private var backup: SarvamSTT?
    private static var lastWarned = Date.distantPast

    private var text: String { (finals + (interim.isEmpty ? [] : [interim])).joined(separator: " ") }

    func connect() {
        guard let key = Keys.deepgram else { markFailed("no key"); return }
        let host = Keys.setting("ASSISTANT_DEEPGRAM_HOST", default: "api.in.deepgram.com")
        var c = URLComponents(string: "wss://\(host)/v1/listen")!
        var items: [URLQueryItem] = [
            .init(name: "model", value: Keys.setting("ASSISTANT_DEEPGRAM_MODEL", default: "nova-3")),
            .init(name: "language", value: Keys.setting("ASSISTANT_DEEPGRAM_LANGUAGE", default: "en-IN")),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"),
            .init(name: "smart_format", value: "true"),
            .init(name: "endpointing", value: "false"),   // we decide when the turn ends (fn-up / local silence)
        ]
        for term in Self.keyterms { items.append(.init(name: "keyterm", value: term)) }
        c.queryItems = items
        var req = URLRequest(url: c.url!)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        let t = s.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
    }

    /// Words Nova-3 should favour. ASSISTANT_STT_KEYTERMS adds more, comma-separated.
    static var keyterms: [String] {
        let extra = Keys.setting("ASSISTANT_STT_KEYTERMS", default: "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ["Quicky"] + extra
    }

    func send(_ chunk: Data) {
        queue.async { [self] in
            audio.append(chunk)
            if let backup { backup.send(chunk); return }
            guard !failed, task != nil else { return }
            guard opened else { outbox.append(chunk); return }
            task?.send(.data(chunk)) { [weak self] err in if let err { self?.markFailed("send: \(err.localizedDescription)") } }
        }
    }

    func finish(timeout: TimeInterval = 3) async -> (String, String?) {
        for _ in 0..<15 where !queue.sync(execute: { opened || failed }) { try? await Task.sleep(nanoseconds: 100_000_000) }
        let neverOpened = queue.sync { () -> Bool in
            if opened && !failed { finalizing = true; sendControl("Finalize") }
            return !opened && !failed
        }
        if neverOpened { markFailed("handshake took over 1.5 s") }
        if let b = queue.sync(execute: { backup }) { return await b.finish(timeout: timeout) }
        if queue.sync(execute: { failed }) { return await restFallback() }
        let result: (String, String?) = await withCheckedContinuation { cont in
            queue.async { [self] in
                if failed { cont.resume(returning: ("", nil)); return }
                finalWaiters.append(cont)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    let waiters = finalWaiters; finalWaiters.removeAll()
                    for w in waiters { w.resume(returning: (text, language)) }
                }
            }
        }
        if let b = queue.sync(execute: { backup }) { closeSocket(); return await b.finish(timeout: timeout) }
        closeSocket()
        if !result.0.isEmpty { return result }
        return await restFallback()
    }

    func close() {
        closeSocket()
        queue.async { [self] in backup?.close(); backup = nil }
    }

    private func closeSocket() {
        queue.async { [self] in
            done = true
            if let task { sendControl("CloseStream"); task.cancel(with: .normalClosure, reason: nil) }
            task = nil
            let waiters = finalWaiters; finalWaiters.removeAll()
            for w in waiters { w.resume(returning: (finals.joined(separator: " "), language)) }
        }
        session?.finishTasksAndInvalidate()
    }

    /// Call on `queue`.
    private func sendControl(_ type: String) {
        guard opened, let task else { return }
        task.send(.string("{\"type\":\"\(type)\"}")) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                if self.queue.sync(execute: { self.task != nil }) { self.markFailed(err.localizedDescription) }
            case .success(let msg):
                switch msg {
                case .string(let s): self.handle(s)
                case .data(let d): if let s = String(data: d, encoding: .utf8) { self.handle(s) }
                @unknown default: break
                }
                self.receive()
            }
        }
    }

    private func handle(_ s: String) {
        if Self.debug { Log.info("dg ← \(s.prefix(300))") }
        guard let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch obj["type"] as? String ?? "" {
        case "Results":
            let alt = ((obj["channel"] as? [String: Any])?["alternatives"] as? [[String: Any]])?.first
            let piece = (alt?["transcript"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let isFinal = obj["is_final"] as? Bool ?? false
            let fromFinalize = obj["from_finalize"] as? Bool ?? false
            queue.async { [self] in
                if isFinal {
                    if !piece.isEmpty { finals.append(piece) }
                    interim = ""
                } else {
                    interim = piece
                }
                if language == nil { language = Self.languageCode }
                let full = text
                DispatchQueue.main.async { self.onPartial?(full) }
                // Finalize flushes everything buffered; the result it produces is the turn's last word.
                if fromFinalize && finalizing {
                    let waiters = finalWaiters; finalWaiters.removeAll()
                    for w in waiters { w.resume(returning: (full, language)) }
                }
            }
        case "Error":
            let message = obj["description"] as? String ?? obj["message"] as? String ?? "Deepgram error"
            Log.error("deepgram: \(message)")
            markFailed(message)
        default:
            break
        }
    }

    /// Nova-3 with a fixed language doesn't report one; hand the app the configured code so TTS matches.
    private static var languageCode: String {
        let l = Keys.setting("ASSISTANT_DEEPGRAM_LANGUAGE", default: "en-IN")
        return l == "multi" ? "en-IN" : (l.hasPrefix("en") ? "en-IN" : l)
    }

    private func markFailed(_ why: String) {
        queue.async { [self] in
            guard !failed, !done else { return }
            failed = true
            Log.error("deepgram failed (\(why)); Sarvam takes over this turn")
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            // Hand the turn to Sarvam's realtime socket, replaying what was recorded so far.
            if Keys.sarvam != nil {
                let b = SarvamSTT()
                b.onPartial = onPartial
                b.onError = onError
                b.connect()
                var i = 0
                while i < audio.count { b.send(audio.subdata(in: i..<min(i + 3200, audio.count))); i += 3200 }
                backup = b
            }
            // One quiet note at most every 10 minutes, not on every turn.
            if Date().timeIntervalSince(Self.lastWarned) > 600 {
                Self.lastWarned = Date()
                let w = why.lowercased()
                let note = w.contains("401") || w.contains("auth") || w.contains("bad server response") || w.contains("no key")
                    ? "Deepgram didn't accept the key; using Sarvam." : "Deepgram is unreachable; using Sarvam."
                DispatchQueue.main.async { self.onError?(note) }
            }
            // A finish() already waiting wakes up, sees the backup and asks Sarvam for the transcript.
            let waiters = finalWaiters; finalWaiters.removeAll()
            for w in waiters { w.resume(returning: ("", nil)) }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        if Self.debug { Log.info("deepgram socket open") }
        queue.async { [self] in
            opened = true
            let pending = outbox; outbox.removeAll()
            for chunk in pending {
                task?.send(.data(chunk)) { [weak self] err in if let err { self?.markFailed("send: \(err.localizedDescription)") } }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let r = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if closeCode != .normalClosure { markFailed("closed \(closeCode.rawValue) \(r)") }
    }

    private func restFallback() async -> (String, String?) {
        let pcm = queue.sync { audio }
        guard pcm.count > 3200 else { return ("", nil) }
        do { return try await SarvamSTT.transcribe(wav: Microphone.wav(pcm)) } catch {
            DispatchQueue.main.async { self.onError?(error.localizedDescription) }
            return ("", nil)
        }
    }
}
