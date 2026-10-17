import XCTest
@testable import QuickyCore

final class SessionTurnTests: XCTestCase {
    let start = Now(monotonicMS: 0, wall: Date(timeIntervalSince1970: 1_700_000_000))

    func testTypedGestureOpensTypingAndOtherGestureOutputIsSilent() {
        var session = Session()
        XCTAssertEqual(session.handle(.input(.key(.fnDown(shift: false))), at: start).disposition, .silent)
        let typed = session.handle(.input(.key(.keyDown(code: 49))), at: Now(monotonicMS: 50, wall: start.wall))
        XCTAssertEqual(typed.disposition, .handled)
        XCTAssertEqual(session.phase, .typing(prefill: ""))
        var other = Session()
        _ = other.handle(.input(.key(.fnDown(shift: false))), at: start)
        let hold = other.handle(.tick, at: Now(monotonicMS: 200, wall: start.wall))
        XCTAssertEqual(hold.disposition, .silent)
        XCTAssertEqual(other.phase, .hidden)
    }

    func testTypedGestureWhileTypingClosesPanel() {
        var session = Session()
        _ = session.handle(.input(.key(.fnDown(shift: true))), at: start)
        XCTAssertEqual(session.phase, .typing(prefill: ""))

        _ = session.handle(.input(.key(.fnUp)), at: Now(monotonicMS: 10, wall: start.wall))
        _ = session.handle(.input(.key(.fnDown(shift: false))), at: Now(monotonicMS: 20, wall: start.wall))
        let closed = session.handle(.input(.key(.keyDown(code: 49))), at: Now(monotonicMS: 30, wall: start.wall))

        XCTAssertEqual(closed.disposition, .handled)
        XCTAssertEqual(session.phase, .hidden)
    }

    func testSubmitStartsTypedTurn() {
        var session = Session()
        let reaction = session.handle(.input(.submit("hello")), at: start)
        guard case let .turn(turn) = session.phase else { return XCTFail("expected turn") }
        XCTAssertEqual(turn.ask.text, "hello")
        XCTAssertEqual(reaction.notices.map(\.type), ["session", "turn"])
        XCTAssertTrue(reaction.effects.contains { if case .chat = $0 { true } else { false } })
    }

    func testEscapeLadder() {
        var hidden = Session()
        XCTAssertEqual(hidden.handle(.input(.escape), at: start).disposition, .notHandled)
        _ = hidden.handle(.input(.key(.fnDown(shift: true))), at: start)
        XCTAssertEqual(hidden.handle(.input(.escape), at: start).disposition, .handled)
        XCTAssertEqual(hidden.phase, .hidden)

        var running = Session(); _ = running.handle(.input(.submit("hello")), at: start)
        let cancelled = running.handle(.input(.escape), at: start)
        XCTAssertEqual(doneOutcome(cancelled), "cancelled")
        XCTAssertEqual(running.phase, .resting)
        XCTAssertEqual(running.handle(.input(.escape), at: start).disposition, .handled)
        XCTAssertEqual(running.phase, .hidden)
    }

    func testDismissTypingAndResting() {
        var typing = Session(); _ = typing.handle(.input(.key(.fnDown(shift: true))), at: start)
        _ = typing.handle(.input(.dismiss(.clickOutside(userScrolled: false))), at: start)
        XCTAssertEqual(typing.phase, .hidden)
        var running = Session(); let begin = running.handle(.input(.submit("hello")), at: start)
        let id = chatID(begin)!; let ended = running.handle(.completion(.ended(id)), at: start)
        XCTAssertEqual(doneOutcome(ended), "answered")
        let ignored = running.handle(.input(.dismiss(.clickOutside(userScrolled: true))), at: start)
        XCTAssertEqual(ignored.notices.first?.type, "ignored")
    }

    func testChatCommandsAndRetry() {
        var log = ChatLog(); _ = log.apply(.new, at: start.wall); _ = log.apply(.new, at: start.wall)
        var session = Session(chats: log)
        _ = session.handle(.input(.submit("x")), at: start)
        let failure = session.handle(.completion(.failed(EffectID("e1"), .transport("offline"))), at: start)
        XCTAssertEqual(doneOutcome(failure), "failed")
        let retry = session.handle(.input(.command(.retry)), at: start)
        XCTAssertTrue(retry.effects.contains { if case .chat = $0 { true } else { false } })
        _ = session.handle(.input(.escape), at: start)
        _ = session.handle(.input(.command(.previousChat)), at: start)
        XCTAssertEqual(session.chats.position, "1 of 2")
        _ = session.handle(.input(.command(.nextChat)), at: start)
        XCTAssertEqual(session.chats.position, "2 of 2")
        _ = session.handle(.input(.command(.newChat)), at: start)
        XCTAssertEqual(session.chats.position, "3 of 3")
    }

    func testTurnStartTokenEnded() {
        var turn = makeTurn(); let id = EffectID("e1")
        XCTAssertEqual(turn.reduce(.start(id, turn.request)).intents, [.chat(id, turn.request)])
        XCTAssertEqual(turn.reduce(.token(id, "  hello")).token, "hello")
        XCTAssertEqual(turn.answer, "hello")
        XCTAssertEqual(turn.reduce(.ended(id)).outcome, .answered)
    }

    func testTransientFailureRetryOnlyOnFirstAttempt() {
        var turn = makeTurn(); let id = EffectID("e1"); _ = turn.reduce(.start(id, turn.request))
        guard case let .failed(_, retry) = turn.reduce(.failed(id, .transport("lost"))).outcome else { return XCTFail() }
        XCTAssertTrue(retry)
        guard case let .failed(_, retry2) = turn.reduce(.failed(id, .forbidden("no"))).outcome else { return XCTFail() }
        XCTAssertFalse(retry2)
    }

    func testCancelAcknowledgementIntent() {
        var turn = makeTurn(); let id = EffectID("e1"); _ = turn.reduce(.start(id, turn.request))
        let result = turn.reduce(.cancel)
        XCTAssertEqual(result.intents, [.cancel(id)])
        XCTAssertEqual(result.outcome, .cancelled)
    }

    func testUnauthorizedReloadsOnceThenFails() {
        var turn = makeTurn(); let first = EffectID("e1"); _ = turn.reduce(.start(first, turn.request))
        XCTAssertEqual(turn.reduce(.unauthorized(first, reload: EffectID("e2"))).intents, [.reloadKeys(EffectID("e2"))])
        XCTAssertEqual(turn.reduce(.keysReloaded(EffectID("e2"), chat: EffectID("e3"))).intents, [.chat(EffectID("e3"), turn.request)])
        guard case let .failed(_, retry) = turn.reduce(.unauthorized(EffectID("e3"), reload: EffectID("e4"))).outcome else { return XCTFail() }
        XCTAssertFalse(retry)
    }

    private func makeTurn() -> Turn {
        let request = Plan.typed(route: .fast).request(ask: "hello", history: [])
        return Turn(id: TurnID("t1"), ask: Ask("hello", route: .fast), request: request)
    }
    private func chatID(_ reaction: Reaction) -> EffectID? { for effect in reaction.effects { if case let .chat(id, _) = effect { return id } }; return nil }
    private func doneOutcome(_ reaction: Reaction) -> String? { if let notice = reaction.notices.first(where: { $0.type == "done" }), case let .string(value) = notice.fields["outcome"] { return value }; return nil }
}
