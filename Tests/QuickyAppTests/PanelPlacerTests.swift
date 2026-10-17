import XCTest
@testable import QuickyApp

final class PanelPlacerTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1440, height: 875)

    func testCentreHangsDownAndRightOfThePointer() {
        let p = PanelPlacer.place(pointer: CGPoint(x: 720, y: 440), width: 560, visible: laptop)
        XCTAssertFalse(p.growsUp)
        XCTAssertEqual(p.maxHeight, 398, "room below the pointer (440 - 18 - 24) is under the 525 cap")
        XCTAssertEqual(p.frame(width: 560, height: 56), CGRect(x: 732, y: 366, width: 560, height: 56))
        XCTAssertEqual(p.frame(width: 560, height: 2000).minY, 24, "never closer than 24 to the bottom")
    }

    func testRightEdgeFlipsToTheLeftOfThePointer() {
        let p = PanelPlacer.place(pointer: CGPoint(x: 1300, y: 700), width: 560, visible: laptop)
        XCTAssertEqual(p.x, 1300 - 12 - 560)
        XCTAssertEqual(p.maxHeight, 525, "60% of 875")
    }

    func testBottomEdgeGrowsUpAndKeepsItsBottomEdge() {
        let p = PanelPlacer.place(pointer: CGPoint(x: 300, y: 40), width: 560, visible: laptop)
        XCTAssertTrue(p.growsUp)
        XCTAssertEqual(p.frame(width: 560, height: 56), CGRect(x: 312, y: 52, width: 560, height: 56))
        XCTAssertEqual(p.frame(width: 560, height: 300).minY, 52, "growth moves the top, not the bottom")
        XCTAssertEqual(p.maxHeight, 525)
    }

    func testSmallScreenClampsInsideTheMargins() {
        let small = CGRect(x: -800, y: 0, width: 800, height: 400)
        let p = PanelPlacer.place(pointer: CGPoint(x: -10, y: 390), width: 560, visible: small)
        let f = p.frame(width: 560, height: 1000)
        XCTAssertEqual(p.maxHeight, 240, "60% of 400")
        XCTAssertEqual(f, CGRect(x: -800 + 216, y: 372 - 240, width: 560, height: 240))
        XCTAssertTrue(small.insetBy(dx: 24, dy: 24).contains(f))
    }
}
