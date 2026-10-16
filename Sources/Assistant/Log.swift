import Foundation
import os

/// Logs to the unified log (subsystem dev.anup.assistant) and to stderr. Never log keys or audio.
enum Log {
    private static let logger = Logger(subsystem: "dev.anup.assistant", category: "app")
    private static let start = Date()

    static func info(_ s: String) { emit("·", s); logger.info("\(s, privacy: .public)") }
    static func error(_ s: String) { emit("!", s); logger.error("\(s, privacy: .public)") }

    /// Timing line, e.g. `Log.time("stt.final", since: t0)`.
    static func time(_ label: String, since t0: Date) {
        info(String(format: "%@ %.0f ms", label, Date().timeIntervalSince(t0) * 1000))
    }

    private static func emit(_ mark: String, _ s: String) {
        let t = String(format: "%7.3f", Date().timeIntervalSince(start))
        FileHandle.standardError.write("\(t) \(mark) \(s)\n".data(using: .utf8)!)
    }
}
