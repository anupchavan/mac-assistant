import Foundation
import Observation

/// The interpreter. Holds the one `Session`, routes each `Effect` to the runner that owns its resource,
/// feeds results back as `Completion`s, and publishes `scene`. `send` does no I/O.
@MainActor @Observable
public final class Engine {
    public private(set) var scene: PanelScene = .hidden
    @ObservationIgnored public var onNotice: (@MainActor (Notice) -> Void)?

    public init(device: any Device, config: Config, storeDirectory: URL) {
        fatalError("not implemented")
    }

    @discardableResult
    public func send(_ input: Input, run: String? = nil) -> Disposition {
        fatalError("not implemented")
    }
}
