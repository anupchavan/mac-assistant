import Foundation

public enum Input: Sendable, Equatable {
    case key(Key)
    case escape
    case submit(String)
    case command(Command)
    case dismiss(Dismissal)
}

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

public enum Disposition: Sendable, Equatable {
    case handled, notHandled, passQuietly
}

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
