import Foundation

public struct SarvamChat: Sendable {
    public var config: Config
    private let recorder: TrafficRecorder?

    public init(config: Config) {
        self.config = config
        self.recorder = config.recordDirectory.map(TrafficRecorder.init)
    }

    public func stream(_ chat: ChatRequest) -> AsyncThrowingStream<String, any Error> {
        let config = config
        let recorder = recorder
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = config.sarvamKey, !key.isEmpty else { throw APIError.unauthorized("missing key") }
                    let body = try JSONEncoder.stable.encode(chat)
                    let path = chat.version + "/chat/completions"
                    var request = URLRequest(url: config.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
                    request.httpMethod = "POST"; request.timeoutInterval = 60; request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
                    request.setValue(key, forHTTPHeaderField: "api-subscription-key")
                    let start = ProcessInfo.processInfo.systemUptime
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse("No HTTP response") }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes.prefix(2000) { data.append(byte) }
                        throw APIError.status(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
                    }
                    var stripper = ThinkStripper()
                    var recorded: [RecordedChunk] = []
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        recorded.append(.init(atMS: Int((ProcessInfo.processInfo.systemUptime - start) * 1000), data: payload))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8), let wire = try? JSONDecoder().decode(StreamChunk.self, from: data) else { continue }
                        if let content = wire.choices.first?.delta.content {
                            let visible = stripper.append(content)
                            if !visible.isEmpty { continuation.yield(visible) }
                        }
                    }
                    let tail = stripper.finish(); if !tail.isEmpty { continuation.yield(tail) }
                    if let recorder { await recorder.append(path: path, body: body, chunks: recorded) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as APIError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    continuation.finish(throwing: APIError.transport(error.localizedDescription))
                } catch {
                    continuation.finish(throwing: APIError.invalidResponse(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable { struct Delta: Decodable { var content: String?; var reasoning: String?; var reasoningContent: String?; enum CodingKeys: String, CodingKey { case content, reasoning, reasoningContent = "reasoning_content" } }; var delta: Delta }
    var choices: [Choice]
}

struct ThinkStripper: Sendable {
    private var buffer = ""
    private var thinking = false

    mutating func append(_ text: String) -> String {
        buffer += text
        var output = ""
        while true {
            let tag = thinking ? "</think>" : "<think>"
            if let range = buffer.range(of: tag) {
                if !thinking { output += buffer[..<range.lowerBound] }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                thinking.toggle()
                continue
            }
            let keep = longestSuffixPrefix(buffer, tag)
            let cut = buffer.index(buffer.endIndex, offsetBy: -keep)
            if !thinking { output += buffer[..<cut] }
            buffer = String(buffer[cut...])
            return output
        }
    }

    mutating func finish() -> String { defer { buffer = "" }; return thinking ? "" : buffer }

    private func longestSuffixPrefix(_ value: String, _ tag: String) -> Int {
        let maximum = min(value.count, tag.count - 1)
        guard maximum > 0 else { return 0 }
        for count in stride(from: maximum, through: 1, by: -1) where value.suffix(count) == tag.prefix(count) { return count }
        return 0
    }
}

private struct RecordedChunk: Sendable, Codable { var atMS: Int; var data: String; enum CodingKeys: String, CodingKey { case atMS = "at_ms", data } }
private struct RecordedRequest: Sendable, Codable { var method: String; var path: String; var bodyJSON: JSONValue; enum CodingKeys: String, CodingKey { case method, path, bodyJSON = "body_json" } }
private struct RecordedResponse: Sendable, Codable { var status: Int; var headers: [String: String]; var sseChunks: [RecordedChunk]; enum CodingKeys: String, CodingKey { case status, headers, sseChunks = "sse_chunks" } }
private struct RecordedExpectation: Sendable, Codable { var request: RecordedRequest; var response: RecordedResponse }

private actor TrafficRecorder {
    let directory: URL
    var expectations: [RecordedExpectation] = []
    init(_ directory: URL) { self.directory = directory }
    func append(path: String, body: Data, chunks: [RecordedChunk]) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body) else { return }
        expectations.append(.init(request: .init(method: "POST", path: path, bodyJSON: json), response: .init(status: 200, headers: ["Content-Type": "text/event-stream"], sseChunks: chunks)))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.stable.encode(expectations) { try? data.write(to: directory.appendingPathComponent("expect.jsonl"), options: .atomic) }
    }
}

public enum JSONValue: Sendable, Equatable, Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else { self = .number(try c.decode(Double.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case let .object(v): try c.encode(v); case let .array(v): try c.encode(v); case let .string(v): try c.encode(v); case let .number(v): try c.encode(v); case let .bool(v): try c.encode(v); case .null: try c.encodeNil() }
    }
}
