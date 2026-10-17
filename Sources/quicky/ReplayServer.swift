import CryptoKit
import Foundation
import Network
import QuickyCore

struct ReplayChunk: Codable, Sendable {
  var atMS: Int
  var data: String
  enum CodingKeys: String, CodingKey {
    case atMS = "at_ms"
    case data
  }
}
struct ReplayRequest: Codable, Sendable {
  var method: String
  var path: String
  var bodyJSON: JSONValue
  var contentSHA256: String?
  enum CodingKeys: String, CodingKey {
    case method, path
    case bodyJSON = "body_json"
    case contentSHA256 = "content_sha256"
  }
}
struct ReplayResponse: Codable, Sendable {
  var status: Int
  var headers: [String: String]
  var sseChunks: [ReplayChunk]
  enum CodingKeys: String, CodingKey {
    case status, headers
    case sseChunks = "sse_chunks"
  }
}
struct ReplayExpectation: Codable, Sendable {
  var request: ReplayRequest
  var response: ReplayResponse
}

actor CancelRelay {
  private var action: (@Sendable () async -> Void)?
  private var fired = false
  func set(_ action: @Sendable @escaping () async -> Void) { self.action = action }
  func fire() async {
    guard !fired else { return }
    fired = true
    await action?()
  }
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
    if let array = try? JSONDecoder().decode([ReplayExpectation].self, from: data) {
      expectations = array
    } else {
      expectations = try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        .map { try JSONDecoder().decode(ReplayExpectation.self, from: Data($0.utf8)) }
    }
    self.cancelAfterMS = cancelAfterMS
    self.relay = relay
  }

  func start() async throws -> UInt16 {
    let listener = try NWListener(using: .tcp, on: .any)
    self.listener = listener
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<UInt16, any Error>) in
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          guard let port = listener.port else { return }
          listener.stateUpdateHandler = nil
          continuation.resume(returning: port.rawValue)
        case .failed(let error):
          listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        default: break
        }
      }
      listener.newConnectionHandler = { [server = self] connection in
        Task { await server.handle(connection) }
      }
      listener.start(queue: .global(qos: .userInitiated))
    }
  }

  func finish() -> String? {
    listener?.cancel()
    if let failure { return failure }
    return next == expectations.count
      ? nil : "replay ended with \(expectations.count - next) unconsumed expectation(s)"
  }

  private func handle(_ connection: NWConnection) async {
    connection.start(queue: .global(qos: .userInitiated))
    do {
      let requestData = try await receiveRequest(connection)
      guard next < expectations.count else { throw ReplayFailure.message("unexpected request") }
      let expected = expectations[next]
      let actual = try parseRequest(requestData)
      guard actual.method == expected.request.method, actual.path == expected.request.path else {
        throw ReplayFailure.message(
          "request mismatch: expected \(expected.request.method) \(expected.request.path), got \(actual.method) \(actual.path)"
        )
      }
      if let expectedHash = expected.request.contentSHA256 {
        guard let systemContent = systemContent(in: actual.body) else {
          throw ReplayFailure.message("request system content is missing")
        }
        guard sha256(systemContent) == expectedHash else {
          throw ReplayFailure.message("request system content hash mismatch")
        }
        guard
          removingSystemContent(from: actual.body)
            == removingSystemContent(from: expected.request.bodyJSON)
        else {
          throw ReplayFailure.message("request body mismatch")
        }
      } else {
        guard actual.body == expected.request.bodyJSON else {
          throw ReplayFailure.message("request body mismatch")
        }
      }
      next += 1
      try await sendResponse(expected.response, on: connection)
    } catch {
      failure = UserError.sanitize(error.localizedDescription)
      try? await send(
        Data("HTTP/1.1 500 Replay Mismatch\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
        on: connection)
    }
    connection.cancel()
  }

  private func receiveRequest(_ connection: NWConnection) async throws -> Data {
    let separator = Data("\r\n\r\n".utf8)
    var data = Data()
    var headerEnd: Data.Index?
    while headerEnd == nil {
      let part = try await receive(on: connection)
      guard !part.isEmpty else {
        throw ReplayFailure.message("connection ended before request headers")
      }
      data.append(part)
      headerEnd = data.range(of: separator)?.upperBound
    }

    let end = headerEnd!
    let header = String(decoding: data[..<(end - separator.count)], as: UTF8.self)
    guard let contentLength = contentLength(in: header) else {
      throw ReplayFailure.message("request is missing Content-Length")
    }
    let requestLength = end + contentLength
    while data.count < requestLength {
      let part = try await receive(on: connection)
      guard !part.isEmpty else {
        throw ReplayFailure.message("connection ended before request body")
      }
      data.append(part)
    }
    return Data(data.prefix(requestLength))
  }

  private func parseRequest(_ data: Data) throws -> (method: String, path: String, body: JSONValue)
  {
    guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else {
      throw ReplayFailure.message("malformed HTTP request")
    }
    let header = String(decoding: data[..<marker.lowerBound], as: UTF8.self)
    let first = header.split(separator: "\n").first?.split(separator: " ") ?? []
    guard first.count >= 2 else { throw ReplayFailure.message("malformed request line") }
    let body = data[marker.upperBound...]
    guard !body.isEmpty else { throw ReplayFailure.message("request body is missing") }
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(body))
    return (String(first[0]), String(first[1]), decoded)
  }

  private func contentLength(in header: String) -> Int? {
    let prefix = "content-length:"
    for line in header.components(separatedBy: "\r\n") where line.lowercased().hasPrefix(prefix) {
      return Int(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
    }
    return nil
  }

  private func sendResponse(_ response: ReplayResponse, on connection: NWConnection) async throws {
    let reason = response.status == 200 ? "OK" : response.status == 401 ? "Unauthorized" : "Error"
    var headers = response.headers
    headers["Connection"] = "close"
    if response.sseChunks.isEmpty {
      headers["Content-Length"] = "0"
    } else {
      headers["Transfer-Encoding"] = "chunked"
      headers["Content-Type"] = "text/event-stream"
    }
    let head =
      "HTTP/1.1 \(response.status) \(reason)\r\n"
      + headers.keys.sorted().map { "\($0): \(headers[$0]!)\r\n" }.joined() + "\r\n"
    try await send(Data(head.utf8), on: connection)
    for chunk in response.sseChunks {
      if let cancelAfterMS, chunk.atMS > cancelAfterMS {
        await relay.fire()
        return
      }
      let payload = Data("data: \(chunk.data)\n\n".utf8)
      let framed =
        Data(String(payload.count, radix: 16).utf8) + Data("\r\n".utf8) + payload
        + Data("\r\n".utf8)
      try await send(framed, on: connection)
      try await Task.sleep(for: .milliseconds(2))
    }
    if !response.sseChunks.isEmpty { try await send(Data("0\r\n\r\n".utf8), on: connection) }
  }

  private func receive(on connection: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, any Error>) in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: data ?? Data())
        }
      }
    }
  }
  private func send(_ data: Data, on connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: ())
          }
        })
    }
  }

  private func systemContent(in value: JSONValue) -> String? {
    guard case .object(let root) = value,
      case .array(let messages)? = root["messages"],
      let first = messages.first,
      case .object(let system) = first,
      case .string(let content)? = system["content"]
    else { return nil }
    return content
  }

  private func removingSystemContent(from value: JSONValue) -> JSONValue {
    guard case .object(var root) = value,
      case .array(var messages)? = root["messages"],
      !messages.isEmpty,
      case .object(var system) = messages[0]
    else { return value }
    system["content"] = nil
    messages[0] = .object(system)
    root["messages"] = .array(messages)
    return .object(root)
  }

  private func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

enum ReplayFailure: LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}
