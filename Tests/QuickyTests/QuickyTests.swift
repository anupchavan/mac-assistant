import XCTest
import ApplicationServices
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
        // Visible actions say nothing: the screen already shows it.
        XCTAssertEqual(AppModel.localReply([close], results: ["pressed"], saidAlready: false, language: "en-IN"), "")
        let find = ToolCall(id: "f", name: "press_shortcut", arguments: ["keys": "cmd+f"], rawArguments: "")
        XCTAssertEqual(AppModel.localReply([find], results: ["pressed"], saidAlready: false, language: nil), "")
        let press = ToolCall(id: "p", name: "press", arguments: ["id": 3], rawArguments: "")
        XCTAssertNil(AppModel.localReply([press], results: ["pressed button “Play”" + Controls.unchangedMarker], saidAlready: false, language: nil))
        XCTAssertEqual(AppModel.localReply([close], results: ["pressed"], saidAlready: true, language: nil), "")
        XCTAssertNil(AppModel.localReply([close], results: ["error: Safari isn't running"], saidAlready: false, language: nil))
        let links = (1...3).map { ToolCall(id: "\($0)", name: "open_url", arguments: ["url": "https://x.com/a\($0)"], rawArguments: "") }
        XCTAssertEqual(AppModel.localReply(links, results: ["opened", "opened", "opened"], saidAlready: false, language: nil), "")
        let search = ToolCall(id: "s", name: "web_search", arguments: ["query": "x"], rawArguments: "")
        XCTAssertNil(AppModel.localReply([search], results: ["[1] …"], saidAlready: false, language: nil))
    }
}

final class BrowserTabsTests: XCTestCase {
    func testMatching() {
        let wanted = ["https://www.instagram.com/porter_in/", "x.com/PorterIndia"].map(BrowserTabs.key)
        XCTAssertTrue(BrowserTabs.matches("https://instagram.com/porter_in?igsh=1", wanted))
        XCTAssertTrue(BrowserTabs.matches("https://x.com/porterindia/status/1", wanted))
        XCTAssertFalse(BrowserTabs.matches("https://www.instagram.com/porter_india", wanted))
        XCTAssertFalse(BrowserTabs.matches("https://porter.in/", wanted))
    }
}

final class ControlTests: XCTestCase {
    func control(_ label: String) -> Control {
        Control(id: 1, role: "button", label: label, state: "", element: AXUIElementCreateSystemWide(), frame: nil)
    }
    func testConsequentialLabelsAskFirst() {
        XCTAssertTrue(control("Block @someone").consequential)
        XCTAssertTrue(control("Delete").consequential)
        XCTAssertTrue(control("Send").consequential)
        XCTAssertFalse(control("Follow").consequential)
        XCTAssertFalse(control("Like").consequential)
        XCTAssertFalse(control("Mute").consequential)
    }
    func testLine() {
        let c = Control(id: 7, role: "switch", label: "Dark mode", state: "off", element: AXUIElementCreateSystemWide(), frame: nil)
        XCTAssertEqual(c.line, "7 | switch | Dark mode (off)")
    }
}

final class TemporalityTests: XCTestCase {
    func testAgo() {
        let now = Date()
        XCTAssertEqual(AppModel.ago(now.addingTimeInterval(-4), now: now), "4 s ago")
        XCTAssertEqual(AppModel.ago(now.addingTimeInterval(-600), now: now), "10 min ago")
        XCTAssertEqual(AppModel.ago(now.addingTimeInterval(-7200), now: now), "2 h ago")
    }
    func testPressedLabel() {
        XCTAssertEqual(Controls.label(from: "pressed button “Follow”"), "Follow")
        let move = ToolCall(id: "m", name: "move_files", arguments: ["paths": ["/a", "/b"], "destination": "/x"], rawArguments: "")
        XCTAssertEqual(AppModel.localReply([move], results: ["moved 2 files"], saidAlready: false, language: nil), "Moved 2 files.")
    }
}

final class ControlLabelTests: XCTestCase {
    func testTidy() {
        XCTAssertEqual(Controls.tidy("Following Down Chevron Icon"), "Following ▾")
        XCTAssertEqual(Controls.tidy("Settings Icon"), "Settings")
        XCTAssertEqual(Controls.tidy("Icon"), "Icon")
        XCTAssertEqual(Controls.tidy("Follow"), "Follow")
    }
    func testNextStep() {
        XCTAssertTrue(Controls.needsNextStep("pressed button “More”" + Controls.unchangedMarker))
        XCTAssertTrue(Controls.needsNextStep("pressed button “Following ▾”" + Controls.openedMarker + "41 | button | Unfollow"))
        XCTAssertFalse(Controls.needsNextStep("pressed button “Follow”"))
    }
}

final class NotSetTests: XCTestCase {
    func testUndoOfSomethingNotDoneIsRefused() {
        XCTAssertEqual(Controls.notSetReply(ask: "Unfollow them.", label: "Follow"), "You're not following them.")
        XCTAssertEqual(Controls.notSetReply(ask: "leave this subreddit", label: "Join"), "You're not a member.")
        XCTAssertNil(Controls.notSetReply(ask: "Unfollow them.", label: "Following ▾"))
        XCTAssertNil(Controls.notSetReply(ask: "follow them", label: "Follow"))
        XCTAssertNil(Controls.notSetReply(ask: "unsubscribe", label: "Subscribed"))
    }
}

final class OpenURLArgsTests: XCTestCase {
    func testURLListAcceptsBothShapes() {
        let one = ToolCall(id: "a", name: "open_url", arguments: ["url": "https://nasa.gov"], rawArguments: "")
        let many = ToolCall(id: "b", name: "open_url", arguments: ["urls": ["https://instagram.com/natgeo", " https://instagram.com/nasa "]], rawArguments: "")
        XCTAssertEqual(one.urlList, ["https://nasa.gov"])
        XCTAssertEqual(many.urlList, ["https://instagram.com/natgeo", "https://instagram.com/nasa"])
        XCTAssertEqual(many.statusText, "Opening 2 links")
    }
}

final class ExtensionTests: XCTestCase {
    func testCuesPickMusic() {
        XCTAssertEqual(Extensions.cueMatch("who sang this song"), ["music"])
        XCTAssertEqual(Extensions.cueMatch("lyrics of tum hi ho"), ["music"])
        XCTAssertEqual(Extensions.cueMatch("open youtube"), [])
    }
    func testOwnerAndReadOnly() {
        XCTAssertEqual(Extensions.owner(of: "lyrics"), "music")
        XCTAssertNil(Extensions.owner(of: "open_url"))
        XCTAssertTrue(Extensions.readOnly("music_search"))
    }
    @MainActor func testPartialMatchesFinal() {
        XCTAssertTrue(ExtensionPicker.close("who sang kun faya", "who sang kun faya kun"))
        XCTAssertFalse(ExtensionPicker.close("open youtube", "who sang kun faya kun"))
    }
    func testSyncedLyricsAroundPosition() {
        let lrc = "[00:01.00] one\n[00:05.00] two\n[00:09.50] three\n[00:12.00] four"
        let out = LRCLib.around(lrc, at: 10)
        XCTAssertTrue(out.contains("▶ three"))
        XCTAssertEqual(LRCLib.strip("[00:01.00] one\n[00:05.00] two"), "one\ntwo")
    }
}

final class ToolSchemaTests: XCTestCase {
    private func call(_ name: String, _ raw: String) -> ToolCall {
        let a = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
        return ToolCall(id: "c", name: name, arguments: a, rawArguments: raw)
    }
    private func problem(_ name: String, _ raw: String) -> String? { ToolSchema.problem(call(name, raw), tools: Tools.declarations) }

    func testGoodCallsPass() {
        XCTAssertNil(problem("open_url", #"{"urls":["https://instagram.com/a","https://x.com/b"]}"#))
        XCTAssertNil(problem("open_url", #"{"url":"https://youtube.com"}"#))      // single-url alias
        XCTAssertNil(problem("press", #"{"id":3}"#))
        XCTAssertNil(problem("type_text", #"{"id":2,"text":"hi","submit":false}"#))
        XCTAssertNil(problem("web_search", #"{"query":"weather","why":"extra keys are ignored"}"#))
        XCTAssertNil(problem("trim_and_merge_videos", #"{"clips":[{"path":"/a.mov","end":"9:35"}]}"#))
    }

    func testShapeProblemsNameTheField() {
        XCTAssertEqual(problem("press", #"{"id":"3"}"#), #"error: press: id should be an integer, got the string "3""#)
        XCTAssertEqual(problem("type_text", #"{"id":2}"#), #"error: type_text: missing required "text""#)
        XCTAssertEqual(problem("type_text", #"{"id":2,"text":"x","submit":"yes"}"#), #"error: type_text: submit should be a boolean, got the string "yes""#)
        XCTAssertEqual(problem("press", #"{"id":true}"#), "error: press: id should be an integer, got a boolean")
        XCTAssertEqual(problem("open_url", #"{"urls":"https://a.com"}"#), #"error: open_url: urls should be an array, got the string "https://a.com""#)
        XCTAssertEqual(problem("trim_and_merge_videos", #"{"clips":[{"start":"0:10"}]}"#), #"error: trim_and_merge_videos: missing required "clips[0].path""#)
    }

    func testLimitsAndValues() {
        let six = (1...6).map { "\"https://a.com/\($0)\"" }.joined(separator: ",")
        XCTAssertEqual(problem("open_url", "{\"urls\":[\(six)]}"), "error: open_url: urls has 6 items, at most 5 allowed")
        XCTAssertEqual(problem("open_url", #"{"urls":["instagram.com/foo"]}"#), #"error: open_url: "instagram.com/foo" is not a full URL; pass complete https:// URLs"#)
        XCTAssertEqual(problem("open_url", #"{"urls":[]}"#), #"error: open_url: "urls" is empty"#)
        XCTAssertNil(problem("open_url", #"{"urls":["spotify:track:1"]}"#))
    }

    func testBrokenJSONAndUnknownTool() {
        XCTAssertEqual(problem("press", #"{"id":3"#), #"error: press arguments are not a JSON object: {"id":3"#)
        XCTAssertTrue(problem("click", "{}")?.hasPrefix(#"error: there is no tool named "click". Tools: web_search, open_url"#) ?? false)
        XCTAssertNil(problem("copy_to_clipboard", #"{"text":"x"}"#))
    }
}

final class AudioTagsTests: XCTestCase {
    func run(_ chunks: [String], speak: Bool) -> (String, String) {
        var f = AudioTags(speakTags: speak)
        var shown = "", spoken = ""
        for c in chunks { let r = f.feed(c); shown += r.shown; spoken += r.spoken }
        let r = f.feed("", end: true); shown += r.shown; spoken += r.spoken
        return (shown, AppModel.cleanForSpeech(spoken))   // the app cleans whitespace before speaking
    }

    func testTagSplitAcrossChunksIsSpokenNotShown() {
        let (shown, spoken) = run(["[si", "ghs] Fine. Four thousand words", " to say go to bed. [chuckles]"], speak: true)
        XCTAssertEqual(shown, "Fine. Four thousand words to say go to bed. ")
        XCTAssertEqual(spoken, "[sighs] Fine. Four thousand words to say go to bed. [chuckles]")
    }

    func testUnknownTagsAndExtraTagsAreDropped() {
        let (shown, spoken) = run(["[screams] No. [laughs] [sighs] [laughs] ok"], speak: true)
        XCTAssertEqual(shown, "No. ok")
        XCTAssertEqual(spoken, "No. [laughs] [sighs] ok")
    }

    func testBulbulNeverHearsTags() {
        XCTAssertEqual(run(["[sighs] Done."], speak: false).1, "Done.")
    }

    func testUnclosedBracketIsText() {
        XCTAssertEqual(run(["Option [a", " is fine"], speak: true).0, "Option [a is fine")
    }

    func testCleanForSpeechKeepsTagsOnly() {
        XCTAssertEqual(AppModel.cleanForSpeech("[sighs] Fine [link"), "[sighs] Fine link")
    }
}
