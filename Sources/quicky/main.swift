import Foundation
import QuickyCore

struct Options {
  var text: String?
  var provider = "live"
  var record: URL?
  var cancelAfterMS: Int?
  var key: String?
  var store: URL?
  var now: Date?
  var panel = false
  var trace = false
  var run: String?
  static func parse(_ args: [String]) throws -> Options {
    guard args.first == "ask" else { throw UsageError() }
    var result = Options()
    var i = 1
    while i < args.count {
      let value = args[i]
      if value.hasPrefix("--") {
        switch value {
        case "--provider":
          i += 1
          result.provider = try required(args, i)
        case "--record":
          i += 1
          result.record = URL(fileURLWithPath: try required(args, i))
        case "--cancel-after-ms":
          i += 1
          result.cancelAfterMS = Int(try required(args, i))
        case "--key":
          i += 1
          result.key = try required(args, i)
        case "--store":
          i += 1
          result.store = URL(fileURLWithPath: try required(args, i))
        case "--now":
          i += 1
          guard let date = ISO8601DateFormatter().date(from: try required(args, i)) else {
            throw UsageError()
          }
          result.now = date
        case "--panel": result.panel = true
        case "--trace": result.trace = true
        case "--run":
          i += 1
          result.run = try required(args, i)
        default: throw UsageError()
        }
      } else if result.text == nil {
        result.text = value
      } else {
        throw UsageError()
      }
      i += 1
    }
    if result.record != nil && result.provider != "live" { throw UsageError() }
    return result
  }
  private static func required(_ args: [String], _ index: Int) throws -> String {
    guard args.indices.contains(index) else { throw UsageError() }
    return args[index]
  }
}
struct UsageError: Error {}

@MainActor
func runCLI() async -> Int32 {
  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments.first == "--app" {
    do {
      let options = try AppOptions.parse(arguments)
      return await AppSocketClient.run(options)
    } catch {
      writeUsage()
      return 64
    }
  }
  let options: Options
  do { options = try Options.parse(arguments) } catch {
    writeUsage()
    return 64
  }
  let storeURL =
    options.store
    ?? FileManager.default.temporaryDirectory.appendingPathComponent(
      "quicky-\(ProcessInfo.processInfo.processIdentifier)")
  var config = Config.load()
  if let key = options.key { config.sarvamKey = key }
  config.recordDirectory = options.record
  let relay = CancelRelay()
  var replay: ReplayServer?
  if options.provider.hasPrefix("replay:") {
    do {
      let server = try ReplayServer(
        directory: URL(fileURLWithPath: String(options.provider.dropFirst("replay:".count))),
        cancelAfterMS: options.cancelAfterMS, relay: relay)
      let port = try await server.start()
      config.baseURL = URL(string: "http://127.0.0.1:\(port)")!
      config.sarvamKey = options.key ?? "replay-key"
      replay = server
    } catch {
      write(
        Notice(
          run: options.run, type: "error",
          fields: ["message": .string(UserError.sanitize(error.localizedDescription))]))
      return 1
    }
  }
  let engine = Engine(
    device: FixtureDevice(), config: config, storeDirectory: storeURL, fixedWall: options.now,
    deviceName: "fixture")
  await relay.set { await MainActor.run { _ = engine.send(.escape, run: options.run) } }
  if options.trace { engine.onTrace = { write($0) } }
  if options.provider == "live", let delay = options.cancelAfterMS {
    Task {
      try? await Task.sleep(for: .milliseconds(delay))
      guard !Task.isCancelled else { return }
      _ = engine.send(.escape, run: options.run)
    }
  }
  var inputs: [InputEnvelope] = []
  if let text = options.text {
    inputs.append(InputEnvelope(.submit(text), run: options.run))
  } else {
    while let line = readLine() {
      if let decoded = try? JSONL.decode(line) { inputs.append(decoded) }
    }
  }
  guard !inputs.isEmpty else { return 64 }
  let isReplay = replay != nil
  let code = await JSONL.run(engine: engine, inputs: inputs) { notice in
    var output = notice
    if isReplay && output.type == "done" {
      var fields = output.fields
      fields["ttft_ms"] = .string("*")
      fields["total_ms"] = .string("*")
      output = Notice(run: output.run, type: output.type, fields: fields)
    }
    write(output)
    if options.panel {
      write(
        Notice(
          run: output.run, type: "panel", fields: ["scene": .string(panelDescription(engine.scene))]
        ))
    }
  }
  if let replay, let failure = await replay.finish() {
    write(Notice(run: options.run, type: "error", fields: ["message": .string(failure)]))
    return 1
  }
  return Int32(code)
}

func writeUsage() {
  FileHandle.standardError.write(
    Data(
      ("usage: quicky ask TEXT [--provider live|replay:DIR] [--record DIR] [--cancel-after-ms N] [--key K] [--store DIR] [--now ISO] [--panel] [--trace] [--run ID]\n"
        + "       quicky --app --run ID [--timeout-ms N] ask TEXT\n"
        + "       quicky --app --run ID [--timeout-ms N] send\n").utf8))
}

func write(_ notice: Notice) {
  if let line = try? JSONL.encode(notice) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
  }
}
func panelDescription(_ scene: PanelScene) -> String {
  scene.presence == .hidden ? "hidden" : "panel thread=\(scene.thread.count)"
}

exit(await runCLI())
