import Foundation
import QuickyCore

struct AppOptions: Sendable {
  var run: String
  var timeoutMS: Int
  var inputs: [InputEnvelope]
  var keyMode: Bool

  static func parse(_ arguments: [String]) throws -> AppOptions {
    guard arguments.first == "--app" else { throw UsageError() }
    var run: String?
    var timeoutMS = 20_000
    var index = 1
    while index < arguments.count, arguments[index].hasPrefix("--") {
      switch arguments[index] {
      case "--run":
        index += 1
        guard arguments.indices.contains(index) else { throw UsageError() }
        run = arguments[index]
      case "--timeout-ms":
        index += 1
        guard arguments.indices.contains(index), let value = Int(arguments[index]), value > 0 else {
          throw UsageError()
        }
        timeoutMS = value
      default: throw UsageError()
      }
      index += 1
    }
    guard let run, arguments.indices.contains(index) else { throw UsageError() }
    let command = arguments[index]
    index += 1
    let inputs: [InputEnvelope]
    switch command {
    case "ask":
      guard index == arguments.count - 1 else { throw UsageError() }
      inputs = [InputEnvelope(.submit(arguments[index]), run: run)]
    case "send":
      guard index == arguments.count else { throw UsageError() }
      let data = FileHandle.standardInput.readDataToEndOfFile()
      guard let body = String(data: data, encoding: .utf8) else { throw UsageError() }
      inputs = try body.split(whereSeparator: \Character.isNewline).map {
        let decoded = try JSONL.decode(String($0))
        return InputEnvelope(decoded.input, run: run)
      }
      guard !inputs.isEmpty else { throw UsageError() }
    default: throw UsageError()
    }
    return AppOptions(
      run: run, timeoutMS: timeoutMS, inputs: inputs,
      keyMode: inputs.contains { if case .key = $0.input { true } else { false } })
  }
}

enum AppSocketClient {
  static func run(_ options: AppOptions) async -> Int32 {
    do {
      return try await Task.detached(priority: .userInitiated) { try runBlocking(options) }.value
    } catch {
      write(
        Notice(
          run: options.run, type: "error",
          fields: ["message": .string(UserError.sanitize(error.localizedDescription))]))
      return 1
    }
  }

  private static func runBlocking(_ options: AppOptions) throws -> Int32 {
    let support = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/dev.anup.assistant")
    let token = try String(contentsOf: support.appending(path: "verify-token"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let descriptor = try connect(to: support.appending(path: "quicky.sock").path)
    defer { close(descriptor) }

    let hello = try JSONSerialization.data(
      withJSONObject: ["type": "hello", "token": token], options: [.sortedKeys])
    guard writeAll(hello + Data("\n".utf8), to: descriptor) else {
      throw AppSocketError.disconnected
    }
    for input in options.inputs {
      let line = try JSONL.encode(input)
      guard writeAll(Data((line + "\n").utf8), to: descriptor) else {
        throw AppSocketError.disconnected
      }
    }

    let timeout = options.keyMode ? min(options.timeoutMS, 500) : options.timeoutMS
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeout))
    var exitCode: Int32 = 0
    var buffer = Data()
    while true {
      let remaining = ContinuousClock.now.duration(to: deadline)
      guard remaining > .zero else { return options.keyMode ? exitCode : 3 }
      let milliseconds = max(1, Int(remaining / .milliseconds(1)))
      var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pollDescriptor, 1, Int32(min(milliseconds, Int(Int32.max))))
      if ready == 0 { return options.keyMode ? exitCode : 3 }
      guard ready > 0 else {
        if errno == EINTR { continue }
        throw AppSocketError.system("poll", errno)
      }
      var bytes = [UInt8](repeating: 0, count: 4096)
      let count = read(descriptor, &bytes, bytes.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw AppSocketError.disconnected }
      buffer.append(contentsOf: bytes.prefix(count))
      while let newline = buffer.firstIndex(of: 0x0a) {
        let lineData = buffer[..<newline]
        buffer.removeSubrange(...newline)
        guard let line = String(data: lineData, encoding: .utf8) else { continue }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["run"] as? String == options.run else { continue }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        if object["type"] as? String == "done", let outcome = object["outcome"] as? String {
          exitCode = outcome == "failed" ? 1 : (outcome == "cancelled" || outcome == "stopped" ? 2 : 0)
        }
        if options.keyMode { return exitCode }
        if object["type"] as? String == "quiet" { return exitCode }
      }
    }
  }

  private static func connect(to path: String) throws -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= pathCapacity else { throw AppSocketError.pathTooLong }
    _ = path.withCString { source in
      withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
        strncpy(destination, source, pathCapacity - 1)
      }
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw AppSocketError.system("socket", errno) }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    address.sun_len = UInt8(length)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Foundation.connect(descriptor, $0, length)
      }
    }
    guard result == 0 else {
      let code = errno
      close(descriptor)
      throw AppSocketError.system("connect", code)
    }
    var noSignal = Int32(1)
    setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
      socklen_t(MemoryLayout.size(ofValue: noSignal)))
    return descriptor
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { rawBuffer in
      guard var pointer = rawBuffer.baseAddress else { return true }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let count = Foundation.write(descriptor, pointer, remaining)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return false }
        remaining -= count
        pointer = pointer.advanced(by: count)
      }
      return true
    }
  }
}

private enum AppSocketError: LocalizedError {
  case disconnected
  case pathTooLong
  case system(String, Int32)

  var errorDescription: String? {
    switch self {
    case .disconnected: "Verification socket disconnected"
    case .pathTooLong: "Unix socket path is too long"
    case .system(let operation, let code): "\(operation) failed (errno \(code))"
    }
  }
}
