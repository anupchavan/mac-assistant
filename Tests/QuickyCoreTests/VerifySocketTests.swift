#if QUICKY_VERIFY
import Foundation
import XCTest
@testable import QuickyCore

private struct VerifyDevice: Device {}

@MainActor
final class VerifySocketTests: XCTestCase {
    func testRejectsBadTokenAndRoutesOwnedRunThroughQuiet() async throws {
        URLProtocol.registerClass(VerifyChatURLProtocol.self)
        defer { URLProtocol.unregisterClass(VerifyChatURLProtocol.self) }

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "q-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appending(path: "quicky.sock")
        let store = directory.appending(path: "store")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try JSONEncoder().encode(StoredState(revision: 0, chats: ChatLog()))
            .write(to: store.appending(path: "state.json"))
        let engine = Engine(
            device: VerifyDevice(),
            config: Config(sarvamKey: "stub", baseURL: URL(string: "https://quicky-socket-test.invalid")!),
            storeDirectory: store)
        let server: VerifySocketServer
        do {
            server = try await JSONL.serve(engine: engine, socketPath: socket)
        } catch where error.localizedDescription.contains("errno 1") {
            throw XCTSkip("The test sandbox forbids binding Unix-domain sockets")
        }
        defer { server.stop() }

        let rejected = try await Task.detached {
            try VerifySocketTestClient.exchange(
                socketPath: socket.path,
                lines: [#"{"type":"hello","token":"wrong"}"#], expectNotices: false)
        }.value
        XCTAssertTrue(rejected.isEmpty)

        let token = try String(contentsOf: directory.appending(path: "verify-token"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let notices = try await Task.detached {
            try VerifySocketTestClient.exchange(
                socketPath: socket.path,
                lines: [
                    #"{"type":"hello","token":"\#(token)"}"#,
                    #"{"type":"ask","run":"r-own","text":"hello"}"#,
                ], expectNotices: true)
        }.value

        let objects = try notices.map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        XCTAssertFalse(objects.isEmpty)
        XCTAssertTrue(objects.allSatisfy { $0["run"] as? String == "r-own" })
        XCTAssertTrue(objects.contains { $0["type"] as? String == "token" })
        XCTAssertTrue(objects.contains { $0["type"] as? String == "done" })
        XCTAssertEqual(objects.last?["type"] as? String, "quiet")
    }
}

private final class VerifyChatURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "quicky-socket-test.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum VerifySocketTestClient {
    static func exchange(socketPath: String, lines: [String], expectNotices: Bool) throws -> [String] {
        let descriptor = try connect(to: socketPath)
        defer { close(descriptor) }
        for line in lines {
            guard writeAll(Data((line + "\n").utf8), to: descriptor) else {
                throw TestSocketError.disconnected
            }
        }
        if !expectNotices {
            shutdown(descriptor, SHUT_WR)
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, 2_000) > 0 else { throw TestSocketError.timeout }
            var byte: UInt8 = 0
            let count = read(descriptor, &byte, 1)
            guard count == 0 else { throw TestSocketError.expectedDisconnect }
            return []
        }

        var notices: [String] = []
        var buffer = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, 250) >= 0 else { throw TestSocketError.system }
            if pollDescriptor.revents == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &bytes, bytes.count)
            guard count > 0 else { throw TestSocketError.disconnected }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 0x0a) {
                let data = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let line = String(data: data, encoding: .utf8) else { continue }
                notices.append(line)
                if line.contains(#""type":"quiet""#) { return notices }
            }
        }
        throw TestSocketError.timeout
    }

    private static func connect(to path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= capacity else { throw TestSocketError.system }
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strncpy(destination, source, capacity - 1)
            }
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TestSocketError.system }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        address.sun_len = UInt8(length)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else { close(descriptor); throw TestSocketError.system }
        var noSignal = Int32(1)
        setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal)))
        return descriptor
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Foundation.write(descriptor, pointer, remaining)
                guard count > 0 else { return false }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
            return true
        }
    }
}

private enum TestSocketError: Error {
    case disconnected, expectedDisconnect, system, timeout
}
#endif
