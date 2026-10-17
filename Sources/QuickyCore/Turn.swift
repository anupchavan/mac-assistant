import Foundation

public struct EffectID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public var rawValue: String; public init(_ rawValue: String) { self.rawValue = rawValue }; public var description: String { rawValue }
}
public struct TurnID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public var rawValue: String; public init(_ rawValue: String) { self.rawValue = rawValue }; public var description: String { rawValue }
}
public struct ChatModel: Sendable, Equatable, Codable { public var name: String; public init(_ name: String) { self.name = name } }
public struct Ask: Sendable, Equatable, Codable { public var text: String; public var route: Route; public init(_ text: String, route: Route) { self.text = text; self.route = route } }
public struct Step: Sendable, Equatable, Codable { public var text: String; public init(_ text: String) { self.text = text } }

public enum Stage: Sendable, Equatable {
    case streaming(EffectID, Attempt)
}
public enum Attempt: Sendable, Equatable {
    case first(ChatModel, reloadedKey: Bool)
}
public enum Outcome: Sendable, Equatable {
    case answered, declined, cancelled, stopped(String), failed(UserError, retry: Bool)
}

public enum TurnEvent: Sendable, Equatable {
    case start(EffectID, ChatRequest)
    case token(EffectID, String)
    case ended(EffectID)
    case failed(EffectID, APIError)
    case unauthorized(EffectID, reload: EffectID)
    case keysReloaded(EffectID, chat: EffectID)
    case cancel
}

public enum TurnIntent: Sendable, Equatable {
    case chat(EffectID, ChatRequest)
    case reloadKeys(EffectID)
    case cancel(EffectID)
}

public struct TurnReduction: Sendable, Equatable {
    public var intents: [TurnIntent] = []
    public var token: String?
    public var outcome: Outcome?
    public init() {}
}

public struct Turn: Sendable, Equatable {
    public let id: TurnID
    public let ask: Ask
    public var answer: String
    public var steps: [Step]
    public var stage: Stage?
    public var request: ChatRequest
    private var pendingReload: EffectID?

    public init(id: TurnID, ask: Ask, request: ChatRequest) {
        self.id = id; self.ask = ask; self.answer = ""; self.steps = []; self.stage = nil; self.request = request
    }

    public mutating func reduce(_ event: TurnEvent) -> TurnReduction {
        var result = TurnReduction()
        switch event {
        case let .start(id, request):
            guard stage == nil else { return result }
            self.request = request
            stage = .streaming(id, .first(ChatModel(request.model), reloadedKey: false))
            result.intents = [.chat(id, request)]
        case let .token(id, text):
            guard activeID == id else { return result }
            let visible = answer.isEmpty ? text.drop(while: { $0.isWhitespace }) : Substring(text)
            answer += visible; result.token = String(visible)
        case let .ended(id):
            guard activeID == id else { return result }
            result.outcome = .answered
        case let .failed(id, error):
            guard activeID == id else { return result }
            let user = UserError(error); result.outcome = .failed(user, retry: error.isTransient)
        case let .unauthorized(id, reloadID):
            guard activeID == id, case let .streaming(_, .first(model, reloaded)) = stage else { return result }
            if reloaded {
                let error = UserError(APIError.unauthorized("")); result.outcome = .failed(error, retry: false)
            } else {
                stage = .streaming(id, .first(model, reloadedKey: true)); pendingReload = reloadID
                result.intents = [.reloadKeys(reloadID)]
            }
        case let .keysReloaded(reloadID, chatID):
            guard pendingReload == reloadID, case let .streaming(_, attempt) = stage else { return result }
            pendingReload = nil; stage = .streaming(chatID, attempt); result.intents = [.chat(chatID, request)]
        case .cancel:
            if let id = activeID { result.intents = [.cancel(id)] }
            result.outcome = .cancelled
        }
        return result
    }

    private var activeID: EffectID? { if case let .streaming(id, _) = stage { id } else { nil } }
}
