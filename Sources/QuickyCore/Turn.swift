import Foundation

public struct EffectID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
  public var rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }
}
public struct TurnID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
  public var rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }
}
public struct ChatModel: Sendable, Equatable, Codable {
  public var name: String
  public init(_ name: String) { self.name = name }
}
public struct Ask: Sendable, Equatable, Codable {
  public var text: String
  public var route: Route
  public init(_ text: String, route: Route) {
    self.text = text
    self.route = route
  }
}
public struct Step: Sendable, Equatable, Codable {
  public var text: String
  public init(_ text: String) { self.text = text }
}

public enum Stage: Sendable, Equatable {
  case streaming(EffectID, Attempt)
}
public enum Attempt: Sendable, Equatable {
  case first(ChatModel, reloadedKey: Bool)
}
public enum Outcome: Sendable, Equatable {
  case answered, declined, cancelled
  case stopped(String)
  case failed(UserError, retry: Bool)
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
    self.id = id
    self.ask = ask
    self.answer = ""
    self.steps = []
    self.stage = nil
    self.request = request
  }

  public mutating func reduce(_ event: TurnEvent) -> TurnReduction {
    var result = TurnReduction()
    switch event {
    case .start(let id, let request):
      guard stage == nil else { return result }
      self.request = request
      stage = .streaming(id, .first(ChatModel(request.model), reloadedKey: false))
      result.intents = [.chat(id, request)]
    case .token(let id, let text):
      guard activeID == id else { return result }
      let visible = answer.isEmpty ? text.drop(while: { $0.isWhitespace }) : Substring(text)
      answer += visible
      result.token = String(visible)
    case .ended(let id):
      guard activeID == id else { return result }
      result.outcome = .answered
    case .failed(let id, let error):
      guard activeID == id else { return result }
      let user = UserError(error)
      result.outcome = .failed(user, retry: error.isTransient)
    case .unauthorized(let id, let reloadID):
      guard activeID == id, case .streaming(_, .first(let model, let reloaded)) = stage else {
        return result
      }
      if reloaded {
        let error = UserError(APIError.unauthorized(""))
        result.outcome = .failed(error, retry: false)
      } else {
        stage = .streaming(id, .first(model, reloadedKey: true))
        pendingReload = reloadID
        result.intents = [.reloadKeys(reloadID)]
      }
    case .keysReloaded(let reloadID, let chatID):
      guard pendingReload == reloadID, case .streaming(_, let attempt) = stage else {
        return result
      }
      pendingReload = nil
      stage = .streaming(chatID, attempt)
      result.intents = [.chat(chatID, request)]
    case .cancel:
      if let id = activeID { result.intents = [.cancel(id)] }
      result.outcome = .cancelled
    }
    return result
  }

  private var activeID: EffectID? { if case .streaming(let id, _) = stage { id } else { nil } }
}
