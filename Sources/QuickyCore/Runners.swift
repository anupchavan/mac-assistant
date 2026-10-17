import Foundation

public actor ChatRun {
    private var config: Config
    public init(config: Config) { self.config = config }

    public func run(_ request: ChatRequest, id: EffectID, emit: @Sendable @escaping (Completion) async -> Void) async {
        do {
            for try await token in SarvamChat(config: config).stream(request) { await emit(.token(id, token)) }
            try Task.checkCancellation(); await emit(.ended(id))
        } catch is CancellationError {
            await emit(.cancelled(id))
        } catch let error as APIError {
            if case .unauthorized = error { await emit(.unauthorized(id)) } else { await emit(.failed(id, error)) }
        } catch {
            await emit(.failed(id, .invalidResponse(error.localizedDescription)))
        }
    }

    public func reload() { config.sarvamKey = Keys.reload() }
}

/// Appends each notice as one JSON line, off the main actor and in order.
public final class NoticeLog: Sendable {
    private let lines: AsyncStream<String>.Continuation

    public init(url: URL) {
        let (stream, lines) = AsyncStream<String>.makeStream()
        self.lines = lines
        Task.detached(priority: .utility) {
            let files = FileManager.default
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !files.fileExists(atPath: url.path) { files.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            _ = try? handle.seekToEnd()
            for await line in stream { try? handle.write(contentsOf: Data((line + "\n").utf8)) }
        }
    }

    public func append(_ notice: Notice) {
        if let line = try? JSONL.encode(notice) { lines.yield(line) }
    }
}
