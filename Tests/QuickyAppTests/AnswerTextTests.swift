import Foundation
import XCTest
@testable import QuickyApp

final class AnswerTextTests: XCTestCase {
    func testUnclosedBoldRendersBoldWhileStreaming() {
        let text = AnswerText.attributed("Say **namas", streaming: true)
        XCTAssertEqual(String(text.characters), "Say namas")
        let bold = text.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertEqual(bold.map { String(text[$0.range].characters) }, "namas")
    }

    func testAJustOpenedMarkerIsHiddenWhileStreaming() {
        XCTAssertEqual(String(AnswerText.attributed("Say `", streaming: true).characters), "Say ")
    }

    func testFinishedAnswerKeepsItsLiteralText() {
        XCTAssertEqual(String(AnswerText.attributed("2 ** 3", streaming: false).characters), "2 ** 3")
    }
}
