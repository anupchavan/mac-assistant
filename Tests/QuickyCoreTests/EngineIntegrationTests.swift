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

    func testReplayLoopbackReadsAndValidatesCompleteURLSessionBody() throws {
        let result = try runQuicky([
            "ask", "Say hello in Hindi",
            "--provider", "replay:Fixtures/replay/hello-hi",
            "--store", temporaryDirectory().path,
        ])

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains(#""type":"token""#))
        XCTAssertFalse(result.output.contains(#""type":"error""#))
    }

    func testReplayRejectsWrongSystemContentHash() throws {
        let fixture = temporaryDirectory()
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let original = try String(contentsOfFile: "Fixtures/replay/hello-hi/expect.jsonl", encoding: .utf8)
        let wrong = original.replacingOccurrences(
            of: "4d4c0b04ac3b66221b8b35af4edfe1525d378fa5460a9dd6e05595cd840de28a",
            with: String(repeating: "0", count: 64)
        )
        try Data(wrong.utf8).write(to: fixture.appendingPathComponent("expect.jsonl"))

        let result = try runQuicky([
            "ask", "Say hello in Hindi",
            "--provider", "replay:\(fixture.path)",
            "--store", temporaryDirectory().path,
        ])

        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.contains(#""type":"error""#))
        XCTAssertTrue(result.output.contains("system content hash mismatch"))
    }

    func testTwoEnginesOnOneStoreAllocateDistinctTurnIDsAndShowBothTurns() throws {
        let directory = temporaryDirectory()
        let store = directory.appendingPathComponent("store")
        let firstFixture = directory.appendingPathComponent("first")
        let secondFixture = directory.appendingPathComponent("second")
        try makeFixture(at: firstFixture, ask: "first", history: [], answer: "one")
        try makeFixture(
            at: secondFixture,
            ask: "second",
            history: [
                ["role": "user", "content": "first"],
                ["role": "assistant", "content": "one"],
            ],
            answer: "two"
        )

        let first = try runQuicky([
            "ask", "first",
            "--provider", "replay:\(firstFixture.path)",
            "--store", store.path,
            "--panel",
        ])
        let second = try runQuicky([
            "ask", "second",
            "--provider", "replay:\(secondFixture.path)",
            "--store", store.path,
            "--panel",
        ])

        XCTAssertEqual(first.status, 0)
        XCTAssertEqual(second.status, 0)
        XCTAssertTrue(first.output.contains(#""turn":"t1""#))
        XCTAssertTrue(second.output.contains(#""turn":"t2""#))
        XCTAssertTrue(second.output.contains(#""scene":"panel thread=2""#))
    }

    private func runQuicky(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let executable = root.appendingPathComponent(".build/debug/quicky")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("quicky executable not built") }
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func makeFixture(at directory: URL, ask: String, history: [[String: String]], answer: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let messages: [[String: String]] = [["role": "system"]] + history + [[
            "role": "user",
            "content": "OUTPUT_MODE: typed\n\nASK: \(ask)",
        ]]
        let expectation: [[String: Any]] = [[
            "request": [
                "method": "POST",
                "path": "/v1/chat/completions",
                "content_sha256": "4d4c0b04ac3b66221b8b35af4edfe1525d378fa5460a9dd6e05595cd840de28a",
                "body_json": [
                    "model": "sarvam-105b",
                    "messages": messages,
                    "stream": true,
                    "max_tokens": 1600,
                    "reasoning_effort": NSNull(),
                ],
            ],
            "response": [
                "status": 200,
                "headers": ["Content-Type": "text/event-stream"],
                "sse_chunks": [
                    ["at_ms": 1, "data": #"{"choices":[{"delta":{"content":"\#(answer)"}}]}"#],
                    ["at_ms": 2, "data": "[DONE]"],
                ],
            ],
        ]]
        let data = try JSONSerialization.data(withJSONObject: expectation, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("expect.jsonl"))
    }
}
