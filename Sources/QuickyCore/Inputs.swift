import Foundation

/// Everything the shell (or the CLI) can tell the core. Slices add cases; nothing is removed.
public enum Input: Sendable, Equatable {
    case key(Key)
    case escape
    case submit(String)
    case command(Command)
    case dismiss(Dismissal)
}

/// Raw key facts from the event tap. Esc never arrives here; it is `Input.escape`.
public enum Key: Sendable, Equatable {
    case fnDown(shift: Bool)
    case fnUp
    case shiftDown
    case keyDown(code: Int)
}

public enum Command: Sendable, Equatable {
    case retry, previousChat, nextChat, newChat
}

public enum Dismissal: Sendable, Equatable {
    case clickOutside(userScrolled: Bool)
    case otherAppActivated(bundleID: String)
}

/// `.handled` swallows a key, `.notHandled` passes it on, `.silent` passes it on and logs nothing.
public enum Disposition: Sendable, Equatable {
    case handled, notHandled, silent
}

/// What the core needs from the Mac. Slice 1 needs nothing; each later slice adds its requirements.
public protocol Device: Sendable {}

public struct Config: Sendable, Equatable {
    public var sarvamKey: String?
    public var chatModel: String
    public var baseURL: URL
    public var recordDirectory: URL?

    public init(sarvamKey: String?, chatModel: String = "sarvam-105b", baseURL: URL = URL(string: "https://api.sarvam.ai")!, recordDirectory: URL? = nil) {
        self.sarvamKey = sarvamKey
        self.chatModel = chatModel
        self.baseURL = baseURL
        self.recordDirectory = recordDirectory
    }

    public static func load() -> Config {
        Config(sarvamKey: Keys.reload(), chatModel: Keys.setting("ASSISTANT_DEEP_MODEL") ?? "sarvam-105b")
    }
}
