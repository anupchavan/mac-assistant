import XCTest
@testable import QuickyCore

enum GestureEvent { case down(Double), shiftDown(Double), shift(Double), up(Double), key(Int, Double), wait(Double) }

final class FnGestureTests: XCTestCase {
    func decisions(_ timeline: [GestureEvent], keepPreroll: Bool = false) -> [FnGesture.Output] {
        var m = FnGesture()
        var out: [FnGesture.Output] = []
        for ev in timeline {
            switch ev {
            case let .down(t): out += m.tick(t) + m.fnDown(t)
            case let .shiftDown(t): out += m.tick(t) + m.fnDown(t, shift: true)
            case let .shift(t): out += m.tick(t) + m.shiftDown(t)
            case let .up(t): out += m.tick(t) + m.fnUp(t)
            case let .key(c, t): out += m.tick(t) + m.otherKeyDown(c, t)
            case let .wait(t): out += m.tick(t)
            }
        }
        return keepPreroll ? out : out.filter { $0 != .preroll }
    }

    func testHold() { XCTAssertEqual(decisions([.down(0), .wait(200), .up(600)]), [.holdBegan, .holdEnded(heldMs: 600)]) }
    func testDoubleTap() { XCTAssertEqual(decisions([.down(0), .up(120), .down(270), .up(390)]), [.handsFree]) }
    func testStrayTap() { XCTAssertEqual(decisions([.down(0), .up(100), .wait(600)]), [.tap]) }
    func testFnArrowNeverFires() { XCTAssertEqual(decisions([.down(0), .key(124, 80), .up(150), .wait(800)]), [.discard]) }
    /// Shift held at fn-down: typed, and never a preroll (the mic must not start).
    func testShiftFn() { XCTAssertEqual(decisions([.shiftDown(0), .up(150), .wait(800)], keepPreroll: true), [.typed]) }
    /// Shift pressed during the hold window: typed (the preroll gets torn down), and no hold follows.
    func testFnThenShift() { XCTAssertEqual(decisions([.down(0), .shift(80), .up(600), .wait(1200)], keepPreroll: true), [.preroll, .typed]) }
    func testFnSpace() { XCTAssertEqual(decisions([.down(0), .key(49, 90), .up(200), .wait(800)]), [.typed]) }
    func testTripleTap() { XCTAssertEqual(decisions([.down(0), .up(80), .down(160), .up(240), .down(320), .up(400)]), [.handsFree, .cancel]) }
    func testShortPressThenNothing() { XCTAssertEqual(decisions([.down(0), .up(150), .wait(700)]), [.tap]) }
    func testDoubleTapSecondHeld() { XCTAssertEqual(decisions([.down(0), .up(100), .down(250), .wait(900), .up(1000)]), [.handsFree]) }
    func testHandsFreeStop() {
        XCTAssertEqual(decisions([.down(0), .up(100), .down(250), .up(330), .down(3000), .up(3080)]), [.handsFree, .handsFreeStop])
    }
}
