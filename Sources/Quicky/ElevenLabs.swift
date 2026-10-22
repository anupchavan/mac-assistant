import Foundation

/// A text-to-speech socket. Text goes in sentence by sentence; 22.05 kHz mono linear16 comes out.
/// `flush` ends the utterance and `onFinal` fires once its last audio has arrived.
protocol TextToSpeech: AnyObject {
    var language: String { get }
    var onAudio: ((Data) -> Void)? { get set }
    var onFinal: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func connect() throws
    func speak(_ text: String)
    func flush()
    func close()
}

extension SarvamTTS: TextToSpeech {}

enum TTS {
    enum Provider: String {
        case sarvam, elevenLabs, elevenLabsTurbo
        var isElevenLabs: Bool { self != .sarvam }
    }

    /// Settings → Voice, else ASSISTANT_TTS_PROVIDER, else Bulbul. ElevenLabs without a key quietly means Bulbul.
    static var chosen: Provider {
        if let v = UserDefaults.standard.string(forKey: "ttsProvider"), let p = Provider(rawValue: v) { return p }
        return Provider(rawValue: Keys.setting("ASSISTANT_TTS_PROVIDER", default: "")) ?? .sarvam
    }

    static var provider: Provider { chosen.isElevenLabs && Keys.elevenLabs == nil ? .sarvam : chosen }

    /// Both play through the same 22.05 kHz player, so audio always plays at its own speed.
    static let sampleRate = 22050

    static func make(language: String, _ p: Provider = provider) -> TextToSpeech {
        switch p {
        case .sarvam: return SarvamTTS(language: language, sampleRate: sampleRate)
        case .elevenLabs: return ElevenLabsTTS(language: language, model: "eleven_v4")
        case .elevenLabsTurbo: return ElevenLabsTTS(language: language, model: "eleven_v4_turbo")
        }
    }
}

// MARK: - ElevenLabs Eleven v4 (Text to Dialogue WebSocket)

/// Eleven v4 streams only over the dialogue socket (the plain TTS socket refuses v3/v4).
/// One registered voice; every sentence is an `inputs` line for it. v4 has no speed setting, so
/// it always speaks at 1x. The server waits for ~40 characters and 8 words before it starts.
/// Warm-socket first audio from Anup's Mac in India: v4 Turbo ~150 ms, v4 ~800 ms (Bulbul ~230 ms).
final class ElevenLabsTTS: NSObject, TextToSpeech, URLSessionWebSocketDelegate {
    /// "Clara V - Warm & Articulate" (British) from the Voice Library.
    static var voice: String { Keys.setting("ELEVENLABS_VOICE_ID", default: "0ggs85h7hrWz8ExXnsBc") }

    var onAudio: ((Data) -> Void)?
    var onFinal: (() -> Void)?
    var onError: ((String) -> Void)?
    let language: String
    let model: String
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var keepAlive: Timer?
    private var oddByte: Data?      // a sample split across two chunks
    private var finished = false    // the server closes the socket after is_final; that isn't an error

    init(language: String, model: String) { self.language = language; self.model = model }

    func connect() throws {
        guard let key = Keys.elevenLabs else { throw MissingKey.elevenLabs }
        var c = URLComponents(string: "wss://api.elevenlabs.io/v1/text-to-dialogue/stream-input")!
        c.queryItems = [.init(name: "model_id", value: model), .init(name: "output_format", value: "pcm_\(TTS.sampleRate)")]
        var req = URLRequest(url: c.url!)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        task = s.webSocketTask(with: req)
        task?.resume()
        send(["voices": [Self.voice]])
        receive()
        // The socket drops after 20 s without a message (a warm spare, or a long tool call mid-answer).
        let t = Timer(timeInterval: 12, repeats: true) { [weak self] _ in self?.send(["keep_alive": true]) }
        RunLoop.main.add(t, forMode: .common)
        keepAlive = t
    }

    /// v4 refuses an input that ends on a tag ("…to bed. [chuckles]"): a tag directs the words after it.
    /// A trailing tag moves to the next sentence, and is dropped if none comes.
    private var heldTags = ""

    func speak(_ text: String) {
        var t = heldTags + text
        heldTags = ""
        if let r = t.range(of: #"(\s*\[[a-z ]+\])+\s*$"#, options: .regularExpression) {
            heldTags = t[r].trimmingCharacters(in: .whitespaces) + " "
            t.removeSubrange(r)
        }
        guard t.range(of: #"\p{L}"#, options: .regularExpression) != nil else { return }
        send(["inputs": [["text": t + " ", "voice_id": Self.voice]]])
    }

    /// End of the utterance: close_socket generates what's buffered and ends with `is_final`.
    func flush() { heldTags = ""; send(["close_socket": true]) }

    func close() {
        keepAlive?.invalidate(); keepAlive = nil
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
                if self.task != nil, !self.finished { DispatchQueue.main.async { self.onError?(err.localizedDescription) } }
            case .success(let msg):
                if case let .string(s) = msg { self.handle(s) }
                if self.task != nil, !self.finished { self.receive() }
            }
        }
    }

    private func handle(_ s: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { return }
        if let b64 = obj["audio"] as? String, var pcm = Data(base64Encoded: b64), !pcm.isEmpty {
            if let odd = oddByte { pcm.insert(contentsOf: odd, at: 0); oddByte = nil }
            if pcm.count % 2 == 1 { oddByte = pcm.suffix(1); pcm.removeLast() }
            onAudio?(pcm)
        }
        if obj["is_final"] as? Bool == true {
            finished = true
            DispatchQueue.main.async { self.keepAlive?.invalidate(); self.onFinal?() }
        }
        if let m = obj["message"] as? String, obj["error"] != nil {
            let safe = APIError(status: obj["code"] as? Int ?? 0, body: m, provider: .elevenLabs).sanitizedMessage
            Log.error("elevenlabs error: \(obj["error"] ?? "") \(safe)")
            DispatchQueue.main.async { self.onError?(safe) }
        }
    }
}

// MARK: - Audio tags

/// Eleven v4 acts out bracketed tags like [sighs]. In a voice turn the answer stream goes through this:
/// tags never reach the panel, the history or Bulbul; ElevenLabs hears only the allowed ones, at most
/// `limit` per answer. A half-arrived "[sig" is held until its "]" streams in.
struct AudioTags {
    /// Reactions that fit Quicky's dry delivery. Prompts.system offers exactly these.
    static let allowed = ["[sighs]", "[chuckles]", "[laughs]", "[deadpan]", "[sarcastic]", "[exhales]", "[whispers]"]
    static let limit = 2

    let speakTags: Bool
    private var pending = ""
    private var used = 0

    init(speakTags: Bool) { self.speakTags = speakTags }

    /// `end` releases anything held (an unclosed "[" was just text).
    mutating func feed(_ chunk: String, end: Bool = false) -> (shown: String, spoken: String) {
        var rest = Substring(pending + chunk)
        pending = ""
        var shown = "", spoken = ""
        var trimShown = false        // "[sighs] Fine." shows as "Fine.", not " Fine."
        func emit(_ s: Substring) {
            spoken += s
            shown += trimShown ? s.drop(while: { $0 == " " }) : s
            if !s.isEmpty { trimShown = false }
        }
        while let open = rest.firstIndex(of: "[") {
            emit(rest[..<open])
            let after = rest[open...]
            guard let close = after.firstIndex(of: "]") else {
                if !end && after.count < 32 { pending = String(after); return (shown, spoken) }
                emit(after); return (shown, spoken)
            }
            let tag = after[...close].lowercased()
            if speakTags, used < Self.limit, Self.allowed.contains(tag) { spoken += tag; used += 1 }
            trimShown = shown.isEmpty || shown.last?.isWhitespace == true
            rest = after[after.index(after: close)...]
        }
        emit(rest)
        return (shown, spoken)
    }
}
