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

public actor NoticeLog {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func append(_ notice: Notice) {
        guard let line = try? JSONL.encode(notice) else { return }
        let data = Data((line + "\n").utf8)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: data); return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close() } catch { try? handle.close() }
    }
}
