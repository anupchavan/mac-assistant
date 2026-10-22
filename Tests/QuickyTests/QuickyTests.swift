import XCTest
@testable import Quicky

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

final class PanelPlacerTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let size = CGSize(width: 560, height: 300)

    /// Bar top 18 under the pointer, panel 12 to its right, growing up from the bar; the cap is what fits above.
    func testCentreGrowsUpFromBar() {
        let p = PanelPlacer.place(pointer: CGPoint(x: 700, y: 500), size: size, visible: screen)
        XCTAssertEqual(p.origin.x, 712)
        XCTAssertEqual(p.origin.y, 500 - 18 - Grid.inputHeight)     // bottom edge anchored under the bar
        XCTAssertTrue(p.growsUp)
        XCTAssertEqual(p.cap, 920 - p.origin.y)                      // room above, under the 560 cap
    }
    func testTopEdgeHangsDown() {
        let p = PanelPlacer.place(pointer: CGPoint(x: 700, y: 900), size: size, visible: screen)
        XCTAssertFalse(p.growsUp)
        XCTAssertEqual(p.origin.y + size.height, 882)               // top edge at the bar's top
        XCTAssertTrue(screen.insetBy(dx: 23, dy: 23).contains(CGRect(origin: p.origin, size: size)))
    }
    func testRightEdgeFlipsLeft() {
        let p = PanelPlacer.place(pointer: CGPoint(x: 1400, y: 500), size: size, visible: screen)
        XCTAssertLessThanOrEqual(p.origin.x + size.width, screen.maxX - 24)
    }
    func testBottomEdgeGrowsUp() {
        let p = PanelPlacer.place(pointer: CGPoint(x: 700, y: 40), size: size, visible: screen)
        XCTAssertTrue(p.growsUp)
        XCTAssertEqual(p.origin.y, 24)                               // bar clamped 24 above the Dock edge
        XCTAssertEqual(p.cap, 560)
    }
    func testBottomRightCorner() {
        let p = PanelPlacer.place(pointer: CGPoint(x: 1500, y: 10), size: size, visible: screen)
        XCTAssertTrue(screen.insetBy(dx: 23, dy: 23).contains(CGRect(origin: p.origin, size: size)))
    }
    func testSecondaryDisplayNegativeOrigin() {
        let s2 = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let p = PanelPlacer.place(pointer: CGPoint(x: -100, y: 540), size: size, visible: s2)
        XCTAssertTrue(s2.insetBy(dx: 23, dy: 23).contains(CGRect(origin: p.origin, size: size)))
    }
    func testCap() { XCTAssertEqual(PanelPlacer.cap(for: screen), 560); XCTAssertEqual(PanelPlacer.cap(for: CGRect(x: 0, y: 0, width: 1000, height: 700)), 420) }
}

final class RouterTests: XCTestCase {
    func testRoutes() {
        XCTAssertEqual(Router.route("block this user", app: "Google Chrome", computerUseAvailable: true), .computer)
        XCTAssertEqual(Router.route("block this user", app: "Google Chrome", computerUseAvailable: false), .fast)
        XCTAssertEqual(Router.route("add this to my calendar", app: "Mail", computerUseAvailable: true), .agent)
        XCTAssertEqual(Router.route("what does this mean", app: "Safari", computerUseAvailable: true), .fast)
        XCTAssertEqual(Router.route("why does this crash", app: "Xcode", computerUseAvailable: true), .deep)
        XCTAssertEqual(Router.route("isko block karo", app: "Arc", computerUseAvailable: true), .computer)
        XCTAssertEqual(Router.route("Can you close this tab?", app: "Safari", computerUseAvailable: true), .agent)
        XCTAssertEqual(Router.route("isko band karo", app: "Safari", computerUseAvailable: true), .agent)
        XCTAssertEqual(Router.route("go back", app: "Safari", computerUseAvailable: true), .agent)
        XCTAssertNotEqual(Router.route("Click.", app: "Safari", computerUseAvailable: true), .computer)
        XCTAssertEqual(Router.route("from the first keep like 09:35 and merge both videos", app: "Finder", computerUseAvailable: true), .agent)
    }
    func testScreenCues() {
        XCTAssertFalse(Router.looksAtScreen("When is Sarvam AI's one trillion parameter model launching?"))
        XCTAssertFalse(Router.looksAtScreen("what's the capital of Australia"))
        XCTAssertTrue(Router.looksAtScreen("what does this mean"))
        XCTAssertTrue(Router.looksAtScreen("summarise"))
        XCTAssertTrue(Router.looksAtScreen("isko simple mein samjhao"))
        XCTAssertTrue(Router.looksAtScreen("ఈ ఫైల్ దేని గురించి?"))
        XCTAssertTrue(Router.looksAtScreen("what's the error"))
    }
    func testFreshCues() {
        XCTAssertTrue(Router.wantsFresh("When is Sarvam AI's one trillion parameter model releasing?"))
        XCTAssertTrue(Router.wantsFresh("what's the weather tomorrow"))
        XCTAssertFalse(Router.wantsFresh("what does this mean"))
    }
    func testSearchParsing() {
        let parallel: [String: Any] = ["results": [["url": "https://a.com/x", "title": "A", "publish_date": "2026-10-01", "excerpts": ["one", "two"]]]]
        XCTAssertEqual(WebSearch.parse(.parallel, parallel).first?.text, "one … two")
        let brave: [String: Any] = ["web": ["results": [["url": "https://b.com", "title": "B", "description": "d", "extra_snippets": ["e"]]]]]
        XCTAssertEqual(WebSearch.parse(.brave, brave).first?.text, "d … e")
        let exa: [String: Any] = ["results": [["url": "https://c.com", "title": "C", "highlights": ["h"]]]]
        XCTAssertEqual(WebSearch.parse(.exa, exa).first?.title, "C")
    }
    func testSpeechCleaning() {
        XCTAssertEqual(AppModel.cleanForSpeech("**Bold** see https://x.com/a now"), "Bold see the link now")
    }
}

final class SpeechGateTests: XCTestCase {
    func testKeyClickAndRoomNoiseAreNotSpeech() {
        var g = SpeechGate()
        g.feed(0.2)                                   // fn click in the first chunk
        for _ in 0..<20 { g.feed(0.006) }             // quiet room
        g.feed(0.03); g.feed(0.004)                   // one bump
        XCTAssertFalse(g.heardSpeech)
    }
    func testSpeechAfterNoise() {
        var g = SpeechGate()
        for _ in 0..<5 { g.feed(0.01) }
        for _ in 0..<4 { g.feed(0.08) }
        XCTAssertTrue(g.heardSpeech)
        for _ in 0..<8 { g.feed(0.01) }
        XCTAssertEqual(g.silenceMs, 800)
    }
    func testNoiseTranscripts() {
        XCTAssertTrue(SpeechGate.isNoise(" ... ", voicedMs: 2000))
        XCTAssertTrue(SpeechGate.isNoise("Thank you.", voicedMs: 400))
        XCTAssertFalse(SpeechGate.isNoise("Thank you.", voicedMs: 1500))
        XCTAssertFalse(SpeechGate.isNoise("close this tab", voicedMs: 400))
    }
}

final class APIErrorTests: XCTestCase {
    func testNoKeyFragmentsOrJSON() {
        let body = #"{"error":{"message":"Incorrect API key provided: sk-proj-AbC1********************xYz9. You can find your API key at https://platform.openai.com/account/api-keys.","type":"invalid_request_error"}}"#
        let e = APIError(status: 401, body: body, provider: .openAI)
        XCTAssertEqual(e.errorDescription, "Your OpenAI key was refused. Paste a working one in Settings (⌘, from the menu-bar ?).")
        XCTAssertFalse(e.sanitizedMessage.contains("sk-"))
        XCTAssertFalse(e.sanitizedMessage.contains("***"))
        XCTAssertLessThanOrEqual(e.sanitizedMessage.count, 80)
        let bad = APIError(status: 400, body: #"{"error":{"message":"Tool messages found but no tools provided.","code":"invalid_request_error"}}"#)
        XCTAssertEqual(bad.errorDescription, "Sarvam returned an error (400): Tool messages found but no tools provided.")
    }
}

final class ControlDoubleTapTests: XCTestCase {
    func testDoubleTapFires() {
        var c = ControlDoubleTap()
        c.down(0); XCTAssertFalse(c.up(90))
        c.down(250); XCTAssertTrue(c.up(330))
    }
    func testTooSlowBetweenTaps() {
        var c = ControlDoubleTap()
        c.down(0); _ = c.up(90)
        c.down(600); XCTAssertFalse(c.up(680))
    }
    func testHeldControlIsNotATap() {
        var c = ControlDoubleTap()
        c.down(0); XCTAssertFalse(c.up(500))
        c.down(600); XCTAssertFalse(c.up(680))
    }
    func testShortcutSpoils() {
        var c = ControlDoubleTap()
        c.down(0); _ = c.up(90)
        c.down(200); c.spoil(); XCTAssertFalse(c.up(260))     // ⌃C as the second press
    }
    func testThirdTapStartsOver() {
        var c = ControlDoubleTap()
        c.down(0); _ = c.up(80); c.down(160); XCTAssertTrue(c.up(240))
        c.down(320); XCTAssertFalse(c.up(400))
    }
}

final class PageLinkTests: XCTestCase {
    func testLinesPutOtherSitesFirstAndDropJunk() {
        let links = [
            PageLink(text: "Pricing", url: "https://porter.in/pricing"),
            PageLink(text: "", url: "javascript:void(0)"),
            PageLink(text: "Instagram", url: "https://www.instagram.com/porter_in/"),
            PageLink(text: "Instagram", url: "https://www.instagram.com/porter_in"),
            PageLink(text: "Top", url: "https://porter.in/pricing#top"),
            PageLink(text: "Mail", url: "mailto:help@porter.in"),
            PageLink(text: "", url: "https://www.linkedin.com/company/porter"),
        ]
        XCTAssertEqual(PageLink.lines(links, pageURL: "https://www.porter.in/"), """
        Instagram | https://www.instagram.com/porter_in/
        - | https://www.linkedin.com/company/porter
        Pricing | https://porter.in/pricing
        """)
    }

    func testLinesCap() {
        let links = (0..<200).map { PageLink(text: "x\($0)", url: "https://site\($0).com/") }
        XCTAssertEqual(PageLink.lines(links, pageURL: "https://a.com", max: 30).split(separator: "\n").count, 30)
    }
}

final class ReflexTests: XCTestCase {
    func keys(_ ask: String) -> String? {
        guard let r = Reflex.match(ask), r.calls.first?.name == "press_shortcut" else { return nil }
        return r.calls[0].string("keys")
    }
    func url(_ ask: String, links: [PageLink] = []) -> String? {
        guard let r = Reflex.match(ask, links: links), r.calls.first?.name == "open_url" else { return nil }
        return r.calls[0].string("url")
    }

    func testShortcuts() {
        XCTAssertEqual(keys("Close this tab."), "cmd+w")
        XCTAssertEqual(keys("hey Quicky, can you close this please"), "cmd+w")
        XCTAssertEqual(keys("New tab"), "cmd+t")
        XCTAssertEqual(keys("go back"), "cmd+[")
        XCTAssertEqual(keys("Refresh the page."), "cmd+r")
        XCTAssertEqual(keys("reopen the last closed tab"), "cmd+shift+t")
        XCTAssertEqual(keys("zoom in"), "cmd+plus")
        XCTAssertEqual(keys("isko band karo"), "cmd+w")
        XCTAssertEqual(keys("next tab"), "ctrl+tab")
    }

    func testLeavesRealQuestionsToTheModel() {
        XCTAssertNil(Reflex.match("close the tab and tell me what it said"))
        XCTAssertNil(Reflex.match("why did it go back"))
        XCTAssertNil(Reflex.match("what does undo mean in git"))
        XCTAssertNil(Reflex.match("open their instagram"))
        XCTAssertNil(Reflex.match("open this link"))
        XCTAssertNil(Reflex.match("quit Safari"))   // destructive: model + confirm
        XCTAssertNil(Reflex.match("restore"))
    }

    func testOpenSitesAndDomains() {
        XCTAssertEqual(url("open youtube"), "https://www.youtube.com")
        XCTAssertEqual(url("Open github.com."), "https://github.com")
        XCTAssertEqual(url("youtube kholo"), "https://www.youtube.com")
        // On a page that links to Instagram, "open instagram" may mean that profile: the model decides.
        XCTAssertNil(url("open instagram", links: [PageLink(text: "Instagram", url: "https://instagram.com/someone")]))
    }

    func testLocalReplyAfterTools() {
        let close = ToolCall(id: "1", name: "press_shortcut", arguments: ["keys": "cmd+w"], rawArguments: "")
        XCTAssertEqual(AppModel.localReply([close], results: ["pressed"], saidAlready: false, language: "en-IN"), "Closed.")
        XCTAssertEqual(AppModel.localReply([close], results: ["pressed"], saidAlready: true, language: nil), "")
        XCTAssertNil(AppModel.localReply([close], results: ["error: Safari isn't running"], saidAlready: false, language: nil))
        XCTAssertNil(AppModel.localReply([close], results: ["pressed"], saidAlready: false, language: "ta-IN"))
        let links = (1...3).map { ToolCall(id: "\($0)", name: "open_url", arguments: ["url": "https://x.com/a\($0)"], rawArguments: "") }
        XCTAssertEqual(AppModel.localReply(links, results: ["opened", "opened", "opened"], saidAlready: false, language: nil), "Opened 3 tabs.")
        let search = ToolCall(id: "s", name: "web_search", arguments: ["query": "x"], rawArguments: "")
        XCTAssertNil(AppModel.localReply([search], results: ["[1] …"], saidAlready: false, language: nil))
    }
}
