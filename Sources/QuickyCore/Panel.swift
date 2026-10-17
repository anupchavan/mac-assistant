import Foundation

public struct PanelScene: Sendable, Equatable {
    public var presence: Presence
    public var input: InputRow
    public var thread: [ThreadItem]
    public var footer: Footer

    public static let hidden = PanelScene(presence: .hidden, input: .idle, thread: [], footer: Footer(primary: nil, chatPosition: nil))

    public init(presence: Presence, input: InputRow, thread: [ThreadItem], footer: Footer) {
        self.presence = presence; self.input = input; self.thread = thread; self.footer = footer
    }

    public init(session: Session) {
        if case .hidden = session.phase { self = .hidden; return }
        var items = session.chats.current?.turns.map { record in
            ThreadItem(id: record.id, ask: record.ask, steps: [], answer: record.answer, error: record.outcome == "failed" ? "Failed" : nil, isLive: false)
        } ?? []
        let input: InputRow
        var primary: FooterAction?
        switch session.phase {
        case .hidden: input = .idle
        case let .typing(prefill): input = .typing(prefill: prefill)
        case let .turn(turn):
            input = .working
            items.removeAll { $0.id == turn.id.rawValue }
            items.append(ThreadItem(id: turn.id.rawValue, ask: turn.ask.text, steps: turn.steps.map { StepRow(text: $0.text, state: .done) }, answer: turn.answer, error: nil, isLive: true))
        case .resting:
            input = .idle
            if session.chats.current?.turns.last?.retry == true { primary = .retry }
        }
        self.init(presence: .panel, input: input, thread: items, footer: Footer(primary: primary, chatPosition: session.chats.position))
    }
}

public enum Presence: Sendable, Equatable {
    case hidden
    case panel
}

public enum InputRow: Sendable, Equatable {
    case idle
    case typing(prefill: String)
    case working
}

public struct ThreadItem: Sendable, Equatable, Identifiable {
    public let id: String
    public var ask: String
    public var steps: [StepRow]
    public var answer: String
    public var error: String?
    public var isLive: Bool
    public init(id: String, ask: String, steps: [StepRow], answer: String, error: String?, isLive: Bool) { self.id = id; self.ask = ask; self.steps = steps; self.answer = answer; self.error = error; self.isLive = isLive }
}

public struct StepRow: Sendable, Equatable {
    public enum State: Sendable, Equatable { case active, done, failed }
    public var text: String
    public var state: State
    public init(text: String, state: State) { self.text = text; self.state = state }
}

public struct Footer: Sendable, Equatable {
    public var primary: FooterAction?
    public var chatPosition: String?
    public init(primary: FooterAction?, chatPosition: String?) { self.primary = primary; self.chatPosition = chatPosition }
}

public enum FooterAction: Sendable, Equatable {
    case retry, openSettings
}

public struct Notice: Sendable, Equatable {
    public let run: String?
    public let type: String
    public let fields: [String: NoticeValue]

    public init(run: String?, type: String, fields: [String: NoticeValue] = [:]) {
        self.run = run; self.type = type; self.fields = fields
    }
}

public enum NoticeValue: Sendable, Equatable {
    case string(String), int(Int), bool(Bool), null
}
