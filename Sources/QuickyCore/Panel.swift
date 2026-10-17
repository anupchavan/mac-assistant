import Foundation

/// What the panel shows, derived purely from the `Session`. The shell renders it and decides nothing.
public struct PanelScene: Sendable, Equatable {
    public var presence: Presence
    public var input: InputRow
    public var thread: [ThreadItem]
    public var footer: Footer

    public static let hidden = PanelScene(presence: .hidden, input: .idle, thread: [], footer: Footer(primary: nil, chatPosition: nil))
}

public enum Presence: Sendable, Equatable {
    case hidden
    case panel
}

public enum InputRow: Sendable, Equatable {
    case idle
    case typing(prefill: String)
    case asked(String)
}

public struct ThreadItem: Sendable, Equatable, Identifiable {
    public let id: String
    public var ask: String
    public var steps: [StepRow]
    public var answer: String
    public var error: String?
    public var isLive: Bool
}

public struct StepRow: Sendable, Equatable {
    public enum State: Sendable, Equatable { case active, done, failed }
    public var text: String
    public var state: State
}

public struct Footer: Sendable, Equatable {
    public var primary: FooterAction?
    public var chatPosition: String?
}

public enum FooterAction: Sendable, Equatable {
    case retry, openSettings
}

/// One line of the JSON Lines protocol, as the CLI, the app log and the verify socket print it.
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
