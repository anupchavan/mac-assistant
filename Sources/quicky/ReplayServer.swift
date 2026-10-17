import Foundation
import Network
import QuickyCore

struct ReplayChunk: Codable, Sendable { var atMS: Int; var data: String; enum CodingKeys: String, CodingKey { case atMS = "at_ms", data } }
struct ReplayRequest: Codable, Sendable { var method: String; var path: String; var bodyJSON: JSONValue; var volatileFields: [String]?; enum CodingKeys: String, CodingKey { case method, path, bodyJSON = "body_json", volatileFields = "volatile_fields" } }
struct ReplayResponse: Codable, Sendable { var status: Int; var headers: [String: String]; var sseChunks: [ReplayChunk]; enum CodingKeys: String, CodingKey { case status, headers, sseChunks = "sse_chunks" } }
struct ReplayExpectation: Codable, Sendable { var request: ReplayRequest; var response: ReplayResponse }

actor CancelRelay {
    private var action: (@Sendable () async -> Void)?
    private var fired = false
    func set(_ action: @Sendable @escaping () async -> Void) { self.action = action }
    func fire() async { guard !fired else { return }; fired = true; await action?() }
}

actor ReplayServer {
    private var expectations: [ReplayExpectation]
    private var next = 0
    private var listener: NWListener?
    private(set) var failure: String?
    private let cancelAfterMS: Int?
    private let relay: CancelRelay

    init(directory: URL, cancelAfterMS: Int?, relay: CancelRelay) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("expect.jsonl"))
        if let array = try? JSONDecoder().decode([ReplayExpectation].self, from: data) { expectations = array }
        else { expectations = try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { try JSONDecoder().decode(ReplayExpectation.self, from: Data($0.utf8)) } }
        self.cancelAfterMS = cancelAfterMS; self.relay = relay
    }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any); self.listener = listener
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port else { return }; listener.stateUpdateHandler = nil; continuation.resume(returning: port.rawValue)
                case let .failed(error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [server = self] connection in Task { await server.handle(connection) } }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func finish() -> String? {
        listener?.cancel()
        if let failure { return failure }
        return next == expectations.count ? nil : "replay ended with \(expectations.count - next) unconsumed expectation(s)"
    }

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))
        do {
            let requestData = try await receiveRequest(connection)
            guard next < expectations.count else { throw ReplayFailure.message("unexpected request") }
            let expected = expectations[next]; let actual = try parseRequest(requestData)
            guard actual.method == expected.request.method, actual.path == expected.request.path else { throw ReplayFailure.message("request mismatch: expected \(expected.request.method) \(expected.request.path), got \(actual.method) \(actual.path)") }
            let fields = expected.request.volatileFields ?? []
            guard removing(fields, from: actual.body) == removing(fields, from: expected.request.bodyJSON) else { throw ReplayFailure.message("request body mismatch") }
            next += 1; try await sendResponse(expected.response, on: connection)
        } catch {
            failure = UserError.sanitize(error.localizedDescription)
            try? await send(Data("HTTP/1.1 500 Replay Mismatch\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), on: connection)
        }
        connection.cancel()
    }

    private func receiveRequest(_ connection: NWConnection) async throws -> Data {
        var all = Data(); var wanted: Int?
        while wanted == nil || all.count < wanted! {
            let part = try await receive(on: connection); guard !part.isEmpty else { break }; all.append(part)
            if wanted == nil, let marker = all.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: all[..<marker.lowerBound], as: UTF8.self)
                let length = header.split(separator: "\n").first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
                wanted = marker.upperBound + length
            }
        }
        return all
    }

    private func parseRequest(_ data: Data) throws -> (method: String, path: String, body: JSONValue) {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else { throw ReplayFailure.message("malformed HTTP request") }
        let header = String(decoding: data[..<marker.lowerBound], as: UTF8.self); let first = header.split(separator: "\n").first?.split(separator: " ") ?? []
        guard first.count >= 2 else { throw ReplayFailure.message("malformed request line") }
        return (String(first[0]), String(first[1]), try JSONDecoder().decode(JSONValue.self, from: data[marker.upperBound...]))
    }

    private func sendResponse(_ response: ReplayResponse, on connection: NWConnection) async throws {
        let reason = response.status == 200 ? "OK" : response.status == 401 ? "Unauthorized" : "Error"
        var headers = response.headers; headers["Connection"] = "close"
        if response.sseChunks.isEmpty { headers["Content-Length"] = "0" } else { headers["Transfer-Encoding"] = "chunked"; headers["Content-Type"] = "text/event-stream" }
        let head = "HTTP/1.1 \(response.status) \(reason)\r\n" + headers.keys.sorted().map { "\($0): \(headers[$0]!)\r\n" }.joined() + "\r\n"
        try await send(Data(head.utf8), on: connection)
        for chunk in response.sseChunks {
            if let cancelAfterMS, chunk.atMS > cancelAfterMS { await relay.fire(); return }
            let payload = Data("data: \(chunk.data)\n\n".utf8); let framed = Data(String(payload.count, radix: 16).utf8) + Data("\r\n".utf8) + payload + Data("\r\n".utf8)
            try await send(framed, on: connection); try await Task.sleep(for: .milliseconds(2))
        }
        if !response.sseChunks.isEmpty { try await send(Data("0\r\n\r\n".utf8), on: connection) }
    }

    private func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) } } }
    }
    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in connection.send(content: data, completion: .contentProcessed { error in if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) } }) }
    }

    private func removing(_ paths: [String], from value: JSONValue) -> JSONValue {
        guard case var .object(root) = value else { return value }
        for path in paths {
            let parts = path.split(separator: ".").map(String.init)
            root = remove(parts, object: root)
        }
        return .object(root)
    }

    private func remove(_ path: [String], object: [String: JSONValue]) -> [String: JSONValue] {
        guard let first = path.first else { return object }
        var result = object
        if path.count == 1 { result[first] = nil; return result }
        guard var child = result[first] else { return result }
        let rest = Array(path.dropFirst())
        if case let .object(value) = child { child = .object(remove(rest, object: value)) }
        else if case var .array(values) = child, let index = Int(rest[0]), values.indices.contains(index) {
            if rest.count == 1, case var .object(item) = values[index] { item[first] = nil; values[index] = .object(item) }
            else if case let .object(item) = values[index] { values[index] = .object(remove(Array(rest.dropFirst()), object: item)) }
            child = .array(values)
        }
        result[first] = child; return result
    }
}

enum ReplayFailure: LocalizedError { case message(String); var errorDescription: String? { if case let .message(value) = self { value } else { nil } } }
