import Foundation

public struct Now: Sendable, Equatable {
    public var monotonicMS: Double
    public var wall: Date
    public init(monotonicMS: Double, wall: Date) { self.monotonicMS = monotonicMS; self.wall = wall }
    public static var real: Now { Now(monotonicMS: ProcessInfo.processInfo.systemUptime * 1000, wall: Date()) }
}

public enum Phase: Sendable, Equatable { case hidden, typing(prefill: String), turn(Turn), resting }
public enum Event: Sendable, Equatable { case input(Input), completion(Completion), tick }
public enum Effect: Sendable, Equatable {
    case chat(EffectID, ChatRequest)
    case reloadKeys(EffectID)
    case cancel(EffectID)
    case persist(EffectID, StoredState)
}
public enum Completion: Sendable, Equatable {
    case token(EffectID, String)
    case ended(EffectID)
    case failed(EffectID, APIError)
    case unauthorized(EffectID)
    case keysReloaded(EffectID)
    case cancelled(EffectID)
    case persisted(EffectID, revision: Int)
}
public struct Reaction: Sendable, Equatable {
    public var effects: [Effect]
    public var notices: [Notice]
    public var disposition: Disposition
    public init(effects: [Effect] = [], notices: [Notice] = [], disposition: Disposition = .notHandled) {
        self.effects = effects; self.notices = notices; self.disposition = disposition
    }
}

public struct Session: Sendable, Equatable {
    public private(set) var phase: Phase = .hidden
    public private(set) var chats: ChatLog
    private var gesture = FnGesture()
    private var nextTurn = 1
    private var nextEffect = 1
    private var revision = 0
    private var pendingQuietRevision: Int?
    private var announcedSession = false
    private var chatModel: String

    public init(chats: ChatLog = ChatLog(), chatModel: String = "sarvam-105b") { self.chats = chats; self.chatModel = chatModel }
    public var nextDeadline: Double? { gesture.deadline }

    public mutating func handle(_ event: Event, at now: Now) -> Reaction {
        switch event {
        case .tick: return handleGesture(gesture.tick(now.monotonicMS), at: now)
        case let .input(input): return handleInput(input, at: now)
        case let .completion(completion): return handleCompletion(completion, at: now)
        }
    }

    private mutating func handleInput(_ input: Input, at now: Now) -> Reaction {
        switch input {
        case let .key(key):
            let outputs: [FnGesture.Output]
            switch key {
            case let .fnDown(shift): outputs = gesture.fnDown(now.monotonicMS, shift: shift)
            case .fnUp: outputs = gesture.fnUp(now.monotonicMS)
            case .shiftDown: outputs = gesture.shiftDown(now.monotonicMS)
            case let .keyDown(code): outputs = gesture.otherKeyDown(code, now.monotonicMS)
            }
            return handleGesture(outputs, at: now)
        case let .submit(text): return submit(text, at: now)
        case .escape: return escape(at: now)
        case let .dismiss(dismissal):
            switch phase {
            case .typing, .resting:
                if case let .clickOutside(scrolled) = dismissal, scrolled { return ignored("dismiss", "thread is scrolled") }
                phase = .hidden; return Reaction(disposition: .handled)
            default: return ignored("dismiss", "current phase cannot dismiss")
            }
        case let .command(value): return handleCommand(value, at: now)
        }
    }

    private mutating func handleGesture(_ outputs: [FnGesture.Output], at now: Now) -> Reaction {
        var reaction = Reaction(disposition: .silent)
        for output in outputs {
            if output == .typed {
                switch phase {
                case .hidden, .resting: phase = .typing(prefill: ""); reaction.disposition = .handled
                default: break
                }
            }
        }
        return reaction
    }

    private mutating func submit(_ raw: String, at now: Now) -> Reaction {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ignored("submit", "ask is empty") }
        switch phase {
        case .hidden, .typing, .resting:
            _ = chats.apply(.continueOrNew, at: now.wall)
            let route = Router.route(text)
            let request = Plan.typed(route: route, model: chatModel).request(ask: text, history: chats.history())
            let turnID = TurnID("t\(nextTurn)"); nextTurn += 1
            let effectID = freshEffect()
            var turn = Turn(id: turnID, ask: Ask(text, route: route), request: request)
            let reduced = turn.reduce(.start(effectID, request))
            phase = .turn(turn)
            var notices: [Notice] = []
            if !announcedSession { announcedSession = true; notices.append(notice("session", ["chat": .string(chats.current!.id), "device": .string("fixture")])) }
            notices.append(notice("turn", ["turn": .string(turnID.rawValue), "ask": .string(text), "mode": .string("typed"), "route": .string(route.rawValue), "chat": .string(chats.current!.id)]))
            return Reaction(effects: effects(reduced.intents), notices: notices, disposition: .handled)
        case .turn: return ignored("submit", "turn is running")
        }
    }

    private mutating func escape(at now: Now) -> Reaction {
        switch phase {
        case .hidden: return Reaction(disposition: .notHandled)
        case .typing: phase = .hidden; return Reaction(disposition: .handled)
        case .resting: phase = .hidden; return Reaction(disposition: .handled)
        case var .turn(turn):
            let reduced = turn.reduce(.cancel)
            return commit(turn: turn, outcome: .cancelled, intents: reduced.intents, at: now)
        }
    }

    private mutating func handleCommand(_ command: Command, at now: Now) -> Reaction {
        guard case .resting = phase else { return ignored("command", "not resting") }
        switch command {
        case .previousChat: _ = chats.apply(.previous, at: now.wall); return chatChanged()
        case .nextChat: _ = chats.apply(.next, at: now.wall); return chatChanged()
        case .newChat: _ = chats.apply(.new, at: now.wall); return chatChanged()
        case .retry:
            guard let record = chats.current?.turns.last, record.retry else { return ignored("command", "nothing retryable") }
            return submit(record.ask, at: now)
        }
    }

    private mutating func handleCompletion(_ completion: Completion, at now: Now) -> Reaction {
        if case let .persisted(_, revision) = completion {
            guard pendingQuietRevision == revision else { return Reaction(disposition: .silent) }
            pendingQuietRevision = nil; return Reaction(notices: [notice("quiet")], disposition: .silent)
        }
        guard case var .turn(turn) = phase else { return Reaction(disposition: .silent) }
        let reduced: TurnReduction
        switch completion {
        case let .token(id, text): reduced = turn.reduce(.token(id, text))
        case let .ended(id): reduced = turn.reduce(.ended(id))
        case let .failed(id, error): reduced = turn.reduce(.failed(id, error))
        case let .unauthorized(id): reduced = turn.reduce(.unauthorized(id, reload: freshEffect()))
        case let .keysReloaded(id): reduced = turn.reduce(.keysReloaded(id, chat: freshEffect()))
        case .cancelled: return Reaction(disposition: .silent)
        case .persisted: return Reaction(disposition: .silent)
        }
        phase = .turn(turn)
        if let outcome = reduced.outcome { return commit(turn: turn, outcome: outcome, intents: reduced.intents, at: now) }
        var notices: [Notice] = []
        if let token = reduced.token, !token.isEmpty { notices.append(notice("token", ["turn": .string(turn.id.rawValue), "text": .string(token)])) }
        if reduced.intents.contains(where: { if case .reloadKeys = $0 { true } else { false } }) { notices.append(notice("step", ["turn": .string(turn.id.rawValue), "text": .string("Reloaded the Sarvam key"), "state": .string("done")])) }
        return Reaction(effects: effects(reduced.intents), notices: notices, disposition: .silent)
    }

    private mutating func commit(turn: Turn, outcome: Outcome, intents: [TurnIntent], at now: Now) -> Reaction {
        let result: (String, Bool, String)
        switch outcome {
        case .answered: result = ("answered", false, "")
        case .declined: result = ("declined", false, "")
        case .cancelled: result = ("cancelled", false, "")
        case let .stopped(reason): result = ("stopped", false, reason)
        case let .failed(error, retry): result = ("failed", retry, error.message)
        }
        chats.apply(.append(.init(id: turn.id.rawValue, ask: turn.ask.text, answer: turn.answer, outcome: result.0, retry: result.1, date: now.wall)), at: now.wall)
        phase = .resting; revision += 1; pendingQuietRevision = revision
        let persistID = freshEffect()
        var notices: [Notice] = []
        if !result.2.isEmpty { notices.append(notice("error", ["message": .string(result.2)])) }
        notices.append(notice("done", ["turn": .string(turn.id.rawValue), "outcome": .string(result.0), "retry": .bool(result.1)]))
        return Reaction(effects: effects(intents) + [.persist(persistID, StoredState(revision: revision, chats: chats))], notices: notices, disposition: .handled)
    }

    private mutating func freshEffect() -> EffectID { defer { nextEffect += 1 }; return EffectID("e\(nextEffect)") }
    private func effects(_ intents: [TurnIntent]) -> [Effect] { intents.map { switch $0 { case let .chat(id, req): .chat(id, req); case let .reloadKeys(id): .reloadKeys(id); case let .cancel(id): .cancel(id) } } }
    private func notice(_ type: String, _ fields: [String: NoticeValue] = [:]) -> Notice { Notice(run: nil, type: type, fields: fields) }
    private func ignored(_ input: String, _ detail: String) -> Reaction { Reaction(notices: [notice("ignored", ["input": .string(input), "detail": .string(detail)])], disposition: .notHandled) }
    private func chatChanged() -> Reaction { Reaction(notices: [notice("session", ["chat": .string(chats.current?.id ?? ""), "device": .string("fixture")])], disposition: .handled) }
}
