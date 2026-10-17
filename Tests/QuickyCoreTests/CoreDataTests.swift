import XCTest
@testable import QuickyCore

final class CoreDataTests: XCTestCase {
    func testReasoningOffEncodesExplicitNull() throws {
        let request = Plan.typed(route: .fast).request(ask: "hi", history: [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertTrue(object.keys.contains("reasoning_effort"))
        XCTAssertTrue(object["reasoning_effort"] is NSNull)
    }

    func testSystemPromptByteStableSHA256() throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum"); process.arguments = ["-a", "256"]
        let input = Pipe(); let output = Pipe(); process.standardInput = input; process.standardOutput = output
        try process.run(); input.fileHandleForWriting.write(Data(Prompt.system.utf8)); try input.fileHandleForWriting.close(); process.waitUntilExit()
        let hash = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").first
        XCTAssertEqual(hash, "4d4c0b04ac3b66221b8b35af4edfe1525d378fa5460a9dd6e05595cd840de28a")
    }

    func testSanitizerRemovesSecretsJSONAndCapsLength() {
        let raw = #"{"key":"sk-abcdefghijklmnopqrstuvwxyz", "other":"***secret", "token":"abcdefghijklmnopqrstuvwxyz0123456789"}"# + String(repeating: "x", count: 100)
        let clean = UserError.sanitize(raw)
        XCTAssertFalse(clean.contains("sk-")); XCTAssertFalse(clean.contains("***")); XCTAssertFalse(clean.contains("{")); XCTAssertLessThanOrEqual(clean.count, 80)
    }

    func testThinkStrippingAcrossBoundaries() {
        var stripper = ThinkStripper()
        XCTAssertEqual(stripper.append("Hi <thi"), "Hi ")
        XCTAssertEqual(stripper.append("nk>secret</thi"), "")
        XCTAssertEqual(stripper.append("nk>there"), "there")
        XCTAssertEqual(stripper.finish(), "")
    }

    func testRouterAndPlans() {
        XCTAssertEqual(Router.route("block this user", computerUseAvailable: true), .computer)
        XCTAssertEqual(Router.route("Click."), .agent)
        XCTAssertEqual(Router.route("why is this broken", app: "Xcode"), .deep)
        XCTAssertEqual(Router.route("hello"), .fast)
        XCTAssertEqual(Plan.typed(route: .fast).maxTokens, 1600)
        XCTAssertEqual(Plan.typed(route: .deep).maxTokens, 4000)
    }

    func testMessageAssemblyHistoryThenUser() {
        let history = [ChatMessage(role: "user", content: "old"), ChatMessage(role: "assistant", content: "answer")]
        let messages = Plan.typed(route: .fast).request(ask: "new", history: history).messages
        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertTrue(messages.last!.content.hasSuffix("ASK: new"))
    }

    func testChatContinueWindowHistoryAndCap() {
        let base = Date(timeIntervalSince1970: 1000); var log = ChatLog(); _ = log.apply(.continueOrNew, at: base)
        let first = log.current!.id; _ = log.apply(.continueOrNew, at: base.addingTimeInterval(300)); XCTAssertEqual(log.current!.id, first)
        _ = log.apply(.continueOrNew, at: base.addingTimeInterval(601)); XCTAssertNotEqual(log.current!.id, first)
        for index in 0..<8 { log.apply(.append(.init(id: "t\(index)", ask: "q\(index)", answer: "a\(index)", outcome: "answered", retry: false, date: base)), at: base) }
        XCTAssertEqual(log.history().count, 12); XCTAssertEqual(log.history().first?.content, "q2")
        for _ in 0..<55 { _ = log.apply(.new, at: base) }
        XCTAssertEqual(log.chats.count, 50)
    }

    func testStoreRevisionOrdering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = Store(directory: directory)
        let newer = try await store.write(.init(revision: 2, chats: ChatLog()))
        let older = try await store.write(.init(revision: 1, chats: ChatLog()))
        let loaded = await store.load()
        XCTAssertTrue(newer); XCTAssertFalse(older); XCTAssertEqual(loaded?.revision, 2)
    }

    func testNoticeStableOrder() throws {
        let line = try JSONL.encode(Notice(run: "r", type: "token", fields: ["z": .int(1), "a": .string("x")]))
        XCTAssertEqual(line, #"{"type":"token","run":"r","a":"x","z":1}"#)
    }

    func testPanelProjection() {
        var session = Session(); _ = session.handle(.input(.submit("hello")), at: .init(monotonicMS: 0, wall: Date()))
        let scene = PanelScene(session: session)
        XCTAssertEqual(scene.presence, .panel); XCTAssertEqual(scene.thread.count, 1); XCTAssertTrue(scene.thread[0].isLive)
    }
}
