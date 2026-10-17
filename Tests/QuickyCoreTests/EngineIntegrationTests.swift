import XCTest
@testable import QuickyCore

private struct EmptyDevice: Device {}

@MainActor
final class EngineIntegrationTests: XCTestCase {
    func testEscapeReturnsUnderFiveMillisecondsWithRunnerOutstanding() {
        let engine = Engine(device: EmptyDevice(), config: Config(sarvamKey: "x", baseURL: URL(string: "http://127.0.0.1:9")!), storeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        engine.send(.submit("hello"))
        let clock = ContinuousClock(); let start = clock.now; engine.send(.escape); let elapsed = start.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .milliseconds(5))
    }

    func testCancelledRunDoesNotPublishLateToken() async {
        let engine = Engine(device: EmptyDevice(), config: Config(sarvamKey: "x", baseURL: URL(string: "http://127.0.0.1:9")!), storeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var notices: [Notice] = []; engine.onNotice = { notices.append($0) }
        engine.send(.submit("hello")); engine.send(.escape)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(notices.contains { $0.type == "token" })
        XCTAssertEqual(notices.first(where: { $0.type == "done" })?.fields["outcome"], .string("cancelled"))
    }

    func testReplayMismatchExitsOne() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let executable = root.appendingPathComponent(".build/debug/quicky")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("quicky executable not built") }
        let process = Process(); process.currentDirectoryURL = root; process.executableURL = executable
        process.arguments = ["ask", "wrong", "--provider", "replay:Fixtures/replay/hello-hi"]
        let output = Pipe(); process.standardOutput = output; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertTrue(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("error"))
    }
}
