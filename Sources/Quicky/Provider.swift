import Foundation

/// The speech + language stack: hearing, answering, speaking. Computer use stays on OpenAI either way.
/// ASSISTANT_PROVIDER=sarvam (in ~/.zshrc) brings back Saaras + sarvam-105b/gemma4 + Bulbul.
enum Provider: String {
    case sarvam, mistral

    static var current: Provider {
        Provider(rawValue: Keys.setting("ASSISTANT_PROVIDER", default: "mistral").lowercased()) ?? .mistral
    }

    var name: String { self == .mistral ? "Mistral" : "Sarvam" }
    var keyNames: [String] { self == .mistral ? Keys.mistralNames : Keys.sarvamNames }

    /// Screenshot questions (image in the prompt).
    var visionModel: String { Keys.setting("ASSISTANT_VISION_MODEL", default: self == .mistral ? "mistral-small-latest" : "gemma4") }
    /// Text-only answers, "think harder", and the computer-use handoff.
    var deepModel: String { Keys.setting("ASSISTANT_DEEP_MODEL", default: self == .mistral ? "mistral-medium-latest" : "sarvam-105b") }

    /// Bulbul is asked for 22.05 kHz; Voxtral TTS only makes 24 kHz. The player must match or speech plays at the wrong speed.
    var ttsSampleRate: Double { self == .mistral ? 24000 : 22050 }

    func makeSTT() -> SpeechToText { self == .mistral ? MistralSTT() : SarvamSTT() }

    func makeTTS(language: String?) -> TextToSpeech {
        self == .mistral ? MistralTTS() : SarvamTTS(language: Sarvam.ttsLanguage(for: language), sampleRate: Int(ttsSampleRate))
    }
}

/// Realtime transcription: audio streams in from fn-down, `finish` returns (text, language like "hi-IN").
protocol SpeechToText: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String, String?) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func connect()
    func send(_ chunk: Data)
    func finish(timeout: TimeInterval) async -> (String, String?)
    func close()
}

extension SpeechToText {
    func finish() async -> (String, String?) { await finish(timeout: 3) }
}

/// Streaming speech: sentences go in as the answer streams, 16-bit mono PCM comes out at the provider's rate.
protocol TextToSpeech: AnyObject {
    var onAudio: ((Data) -> Void)? { get set }
    var onFinal: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func connect() throws
    func speak(_ text: String)
    func flush()
    func close()
}

extension SarvamSTT: SpeechToText {}
extension SarvamTTS: TextToSpeech {}

/// Chat completions for whichever provider is current. `version` only matters to Sarvam (/v2 takes images).
enum LLM {
    static func stream(model: String, version: SarvamChat.Version, messages: [[String: Any]], tools: [[String: Any]]? = nil,
                       toolChoice: String = "auto", reasoning: String? = nil, maxTokens: Int, temperature: Double? = nil,
                       json: Bool = false) -> AsyncThrowingStream<ChatEvent, Error> {
        switch Provider.current {
        case .sarvam:
            return SarvamChat.stream(model: model, version: version, messages: messages, tools: tools, toolChoice: toolChoice,
                                     reasoning: reasoning, maxTokens: maxTokens, temperature: temperature, json: json)
        case .mistral:
            return MistralChat.stream(model: model, messages: messages, tools: tools, toolChoice: toolChoice,
                                      reasoning: reasoning, maxTokens: maxTokens, temperature: temperature, json: json)
        }
    }

    static func complete(model: String, version: SarvamChat.Version = .v1, messages: [[String: Any]], reasoning: String? = nil,
                         maxTokens: Int, json: Bool = false) async throws -> String {
        var out = ""
        for try await e in stream(model: model, version: version, messages: messages, reasoning: reasoning, maxTokens: maxTokens, json: json) {
            if case let .text(t) = e { out += t }
        }
        return out
    }
}
