#if QUICKY_VERIFY
import Foundation

public final class VerifySocketServer: @unchecked Sendable {
    private let descriptor: Int32
    private let socketPath: String
    private let engine: Engine
    private let lock = NSLock()
    private var stopped = false
    private var acceptTask: Task<Void, Never>?

    fileprivate init(engine: Engine, socketPath: URL, tokenPath: URL) throws {
        self.engine = engine
        self.socketPath = socketPath.path

        let files = FileManager.default
        try files.createDirectory(at: socketPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: tokenPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try Data((token + "\n").utf8).write(to: tokenPath, options: .atomic)
        guard chmod(tokenPath.path, S_IRUSR | S_IWUSR) == 0 else {
            throw VerifySocketError.system("chmod token", errno)
        }

        unlink(self.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VerifySocketError.system("socket", errno) }
        do {
            try Self.bind(fd, to: self.socketPath)
            guard chmod(self.socketPath, S_IRUSR | S_IWUSR) == 0 else {
                throw VerifySocketError.system("chmod socket", errno)
            }
            guard listen(fd, 8) == 0 else { throw VerifySocketError.system("listen", errno) }
        } catch {
            close(fd)
            unlink(self.socketPath)
            throw error
        }
        descriptor = fd
        acceptTask = Task.detached(priority: .utility) { [self] in acceptConnections(token: token) }
    }

    deinit { stop() }

    public func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let task = acceptTask
        lock.unlock()
        task?.cancel()
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(socketPath)
    }

    private func acceptConnections(token: String) {
        while !Task.isCancelled {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                lock.lock(); let done = stopped; lock.unlock()
                if done { return }
                continue
            }
            var noSignal = Int32(1)
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
            Task.detached(priority: .utility) { [engine] in
                await Self.handle(client: client, token: token, engine: engine)
            }
        }
    }

    private static func handle(client: Int32, token: String, engine: Engine) async {
        defer { close(client) }
        guard let hello = readLine(from: client), JSONL.verificationHelloIsValid(hello, token: token) else { return }

        let (stream, continuation) = AsyncStream<String>.makeStream()
        let router = VerifyNoticeRouter(continuation: continuation)
        let observerID = await MainActor.run {
            engine.addNoticeObserver { notice in router.publish(notice) }
        }
        let writer = Task.detached(priority: .utility) {
            for await line in stream {
                guard writeAll(Data((line + "\n").utf8), to: client) else { return }
            }
        }
        while let line = readLine(from: client) {
            guard let envelope = try? JSONL.decode(line) else { continue }
            if let run = envelope.run { router.add(run: run) }
            await MainActor.run { _ = engine.send(envelope.input, run: envelope.run) }
        }
        continuation.finish()
        writer.cancel()
        await MainActor.run { engine.removeNoticeObserver(observerID) }
    }

    private static func bind(_ descriptor: Int32, to path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw VerifySocketError.pathTooLong
        }
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strncpy(destination, source, pathCapacity - 1)
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        address.sun_len = UInt8(length)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(descriptor, $0, length)
            }
        }
        guard result == 0 else { throw VerifySocketError.system("bind", errno) }
    }

    private static func readLine(from descriptor: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 1_048_576 {
            let count = withUnsafeMutablePointer(to: &byte) { read(descriptor, $0, 1) }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return nil }
            if byte == 0x0a { return String(data: data, encoding: .utf8) }
            data.append(byte)
        }
        return nil
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = write(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
            return true
        }
    }
}

private final class VerifyNoticeRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: Set<String> = []
    private let continuation: AsyncStream<String>.Continuation

    init(continuation: AsyncStream<String>.Continuation) {
        self.continuation = continuation
    }

    func add(run: String) {
        lock.lock(); runs.insert(run); lock.unlock()
    }

    func publish(_ notice: Notice) {
        lock.lock()
        let matches = JSONL.verificationNoticeMatches(notice, runs: runs)
        if matches, notice.type == "quiet", let run = notice.run { runs.remove(run) }
        lock.unlock()
        guard matches, let line = try? JSONL.encode(notice) else { return }
        continuation.yield(line)
    }
}

public extension JSONL {
    @MainActor
    static func serve(engine: Engine, socketPath: URL? = nil) async throws -> VerifySocketServer {
        let path = socketPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/dev.anup.assistant/quicky.sock")
        let tokenPath = path.deletingLastPathComponent().appending(path: "verify-token")
        return try await Task.detached(priority: .utility) {
            try VerifySocketServer(engine: engine, socketPath: path, tokenPath: tokenPath)
        }.value
    }
}

private enum VerifySocketError: LocalizedError {
    case pathTooLong
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong: "Unix socket path is too long"
        case .system(let operation, let code): "\(operation) failed (errno \(code))"
        }
    }
}
#endif
