import AppKit
import Foundation
import SwiftUI

/// Command-line checks against the real APIs, run from the built binary:
///   Assistant --probe keys
///   Assistant --probe chat "what is 2+2"          (sarvam-105b, prints TTFT)
///   Assistant --probe agent "open google.com" [v1] (agent route request; v1 = sarvam-105b instead of gemma4)
///   Assistant --probe vision                      (front window → gemma4 on /v2; tells you if V2 is whitelisted)
///   Assistant --probe context                     (prints the context block for the front app)
///   Assistant --probe tts "namaste" [hi-IN]       (Bulbul socket, plays it, prints first-audio latency)
///   Assistant --probe stt [seconds]               (records from the mic, realtime STT, prints the transcript)
///   Assistant --probe route "block this user"
///   Assistant --probe handoff "block this user"   (computer-use instruction only; never clicks)
///   Assistant --probe render <dir>                (offscreen PNGs of the panel states; nothing appears on screen)
///   Assistant --probe gesture                     (replays fn timelines through the state machine)
enum Probe {
    static func run(_ args: [String]) {
        let cmd = args.first ?? "keys"
        let rest = Array(args.dropFirst())
        let done = DispatchSemaphore(value: 0)
        Task {
            do { try await dispatch(cmd, rest) } catch { print("error: \(error.localizedDescription)") }
            done.signal()
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    static func dispatch(_ cmd: String, _ rest: [String]) async throws {
        switch cmd {
        case "keys":
            print(Keys.report())
        case "chat":
            let q = rest.first ?? "Say hello in Hindi in five words."
            let t0 = Date()
            var first: Date?
            for try await e in SarvamChat.stream(model: Keys.setting("ASSISTANT_DEEP_MODEL", default: "sarvam-105b"), version: .v1,
                                                 messages: [["role": "system", "content": Prompts.system], ["role": "user", "content": "OUTPUT_MODE: typed\n\nASK: \(q)"]],
                                                 reasoning: nil, maxTokens: 600) {
                if case let .text(t) = e { if first == nil { first = Date() }; print(t, terminator: ""); fflush(stdout) }
            }
            print(String(format: "\n— TTFT %.0f ms, total %.0f ms", ((first ?? Date()).timeIntervalSince(t0)) * 1000, Date().timeIntervalSince(t0) * 1000))
        case "agent":
            // The agent route exactly as the app sends it: gemma4 on /v2 with the screenshot and tools,
            // or sarvam-105b on /v1 with tools when given "v1".
            let ask = rest.first ?? "open google.com"
            let v1 = rest.dropFirst().first == "v1"
            let ctx = await ContextCapture.capture()
            var content: Any = ctx.block(language: nil, outputMode: "typed", includeOCR: false) + "\n\nASK: \(ask)"
            if !v1, let shot = ctx.screenshot, let url = ContextCapture.jpegDataURL(shot) {
                content = [["type": "text", "text": ctx.block(language: nil, outputMode: "typed", includeOCR: false)],
                           ["type": "image_url", "image_url": ["url": url]],
                           ["type": "text", "text": "ASK: \(ask)"]] as [[String: Any]]
            }
            let model = v1 ? Keys.setting("ASSISTANT_DEEP_MODEL", default: "sarvam-105b") : Keys.setting("ASSISTANT_VISION_MODEL", default: "gemma4")
            var messages: [[String: Any]] = [["role": "system", "content": Prompts.system], ["role": "user", "content": content]]
            var call: (id: String, name: String, args: String)?
            var text = ""
            let t0 = Date()
            for try await e in SarvamChat.stream(model: model, version: v1 ? .v1 : .v2, messages: messages,
                                                 tools: Tools.declarations, reasoning: nil, maxTokens: 600) {
                switch e {
                case .text(let t): text += t; print(t, terminator: "")
                case .toolCallDelta(_, let id, let name, let args):
                    var c = call ?? ("", "", ""); if let id { c.id = id }; c.name += name ?? ""; c.args += args ?? ""; call = c
                case .finished(let f): print("[finish \(f)]")
                default: break
                }
            }
            print(String(format: "— %@ %.0f ms", model, Date().timeIntervalSince(t0) * 1000))
            guard let call else { return }
            print("tool call: \(call.name) \(call.args)  (not run; replying \"opened\")")
            // The follow-up, shaped exactly like AppModel.streamAnswer's.
            messages.append(["role": "assistant", "content": text,
                             "tool_calls": [["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.args]]]])
            messages.append(["role": "tool", "tool_call_id": call.id, "content": "opened"])
            for try await e in SarvamChat.stream(model: model, version: v1 ? .v1 : .v2, messages: messages, tools: Tools.declarations, toolChoice: "none", reasoning: nil, maxTokens: 300) {
                if case .text(let t) = e { print(t, terminator: "") }
            }
            print(String(format: "\n— follow-up OK, %.0f ms total", Date().timeIntervalSince(t0) * 1000))
        case "render":
            // Draws the real panel views with fixture state into windows that are never shown, and saves PNGs (2x).
            let dir = URL(fileURLWithPath: rest.first ?? NSTemporaryDirectory())
            await MainActor.run { RenderProbe.run(into: dir) }
        case "cua-access":
            // One text-only Responses request per computer-use model; no screenshot, nothing executed.
            guard let key = Keys.openAI else { print("OpenAI key: missing"); return }
            for model in [Keys.setting("ASSISTANT_CUA_MODEL", default: "gpt-6-astra"), Keys.setting("ASSISTANT_CUA_FALLBACK_MODEL", default: "gpt-6.1-sol")] {
                let t0 = Date()
                do {
                    let r = try await ComputerUser.post(["model": model, "tools": [["type": "computer"]], "max_output_tokens": 64,
                                                         "input": "Reply with the word ok. Do not use the computer."], key: key)
                    let types = (r["output"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
                    print(String(format: "%@: HTTP 200, output %@ (%.0f ms)", model, types.joined(separator: ", "), Date().timeIntervalSince(t0) * 1000))
                } catch let e as APIError {
                    print("\(model): HTTP \(e.status), \(e.sanitizedMessage)")
                }
            }
        case "vision":
            let ctx = await ContextCapture.capture()
            guard let shot = ctx.screenshot, let url = ContextCapture.jpegDataURL(shot) else { print("no screenshot (grant Screen Recording to the terminal/app)"); return }
            let t0 = Date()
            do {
                let text = try await SarvamChat.complete(model: Keys.setting("ASSISTANT_VISION_MODEL", default: "gemma4"), version: .v2, messages: [
                    ["role": "user", "content": [["type": "text", "text": "What app and content is shown? One sentence."],
                                                 ["type": "image_url", "image_url": ["url": url]]] as [[String: Any]]],
                ], maxTokens: 200)
                print(text)
                print(String(format: "— vision OK (%.0f ms). V2 is enabled for this key.", Date().timeIntervalSince(t0) * 1000))
            } catch {
                print("— vision FAILED: \(error.localizedDescription)\nThe app will fall back to on-device OCR + sarvam-105b.")
            }
        case "context":
            await ContextCapture.warmUp()   // the app does this at launch
            let ctx = await ContextCapture.capture()
            print(ctx.block(language: nil, outputMode: "typed", includeOCR: false))
            print("screenshot: \(ctx.screenshot.map { "\($0.width)x\($0.height)" } ?? "none"), \(Int(ctx.captureMs)) ms")
        case "tts":
            let text = rest.first ?? "Namaste! Main aapki screen dekh sakta hoon."
            let lang = rest.dropFirst().first ?? "hi-IN"
            let player = PCMPlayer(sampleRate: 22050)
            let tts = SarvamTTS(language: lang)
            let t0 = Date()
            var first = true
            let finished = DispatchSemaphore(value: 0)
            tts.onAudio = { pcm in
                if first { first = false; print(String(format: "first audio %.0f ms", Date().timeIntervalSince(t0) * 1000)) }
                player.enqueue(int16: pcm)
            }
            tts.onFinal = { finished.signal() }
            tts.onError = { m in print("tts error: \(m)"); finished.signal() }
            try tts.connect()
            tts.speak(text)
            tts.flush()
            _ = await withCheckedContinuation { c in DispatchQueue.global().async { c.resume(returning: finished.wait(timeout: .now() + 20)) } }
            try await Task.sleep(nanoseconds: UInt64((player.scheduledSeconds - player.playedSeconds + 0.3) * 1e9))
            print(String(format: "audio %.1fs", player.scheduledSeconds))
            tts.close()
        case "stt":
            let secs = Double(rest.first ?? "4") ?? 4
            let mic = Microphone()
            let stt = SarvamSTT()
            stt.onPartial = { print("… \($0)") }
            stt.onError = { print("stt error: \($0)") }
            stt.connect()
            mic.onChunk = { chunk, _ in stt.send(chunk) }
            try mic.start()
            print("speak now for \(Int(secs))s")
            try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
            mic.stop()
            let t0 = Date()
            let (text, lang) = await stt.finish()
            print(String(format: "final (%@) after %.0f ms: %@", lang ?? "?", Date().timeIntervalSince(t0) * 1000, text))
        case "route":
            let ask = rest.joined(separator: " ")
            print(Router.route(ask, app: "Google Chrome", computerUseAvailable: true).rawValue)
        case "handoff":
            let ctx = await ContextCapture.capture()
            switch try await ComputerUser.handoff(ask: rest.joined(separator: " "), context: ctx, language: nil) {
            case .success(let h): print("task: \(h.task)\ntarget: \(h.target)\nconsequential: \(h.consequential)\nconfirm: \(h.confirmText)")
            case .failure(let q): print("ask user: \(q)")
            }
        case "gesture":
            for (name, timeline) in GestureFixtures.all {
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
                print("\(name): \(out.filter { $0 != .preroll })")
            }
        default:
            print("unknown probe \(cmd)")
        }
    }
}

enum GestureEvent { case down(Double), shiftDown(Double), shift(Double), up(Double), key(Int, Double), wait(Double) }

enum GestureFixtures {
    static let all: [(String, [GestureEvent])] = [
        ("hold 600 ms", [.down(0), .wait(200), .up(600)]),
        ("double tap", [.down(0), .up(120), .down(270), .up(390)]),
        ("stray tap", [.down(0), .up(100), .wait(600)]),
        ("fn+arrow", [.down(0), .key(124, 80), .up(150)]),
        ("fn+space", [.down(0), .key(49, 90), .up(200)]),
        ("triple tap", [.down(0), .up(80), .down(160), .up(240), .down(320), .up(400)]),
        ("hold 150 then nothing", [.down(0), .up(150), .wait(700)]),
        ("double tap, 2nd held", [.down(0), .up(100), .down(250), .wait(900), .up(1000)]),
        ("shift+fn", [.shiftDown(0), .up(150), .wait(800)]),
        ("fn then shift", [.down(0), .shift(80), .up(300), .wait(800)]),
        ("hands-free then tap", [.down(0), .up(100), .down(250), .up(330), .down(3000), .up(3080)]),
    ]
}

/// Offscreen renders for checking layout by pixels. Fixture state only; nothing is saved to the chat store.
@MainActor
enum RenderProbe {
    static func run(into dir: URL) {
        _ = NSApplication.shared
        Fonts.register()
        let m = AppModel()
        var ctx = ScreenContext()
        ctx.appName = "Safari"; ctx.bundleID = "com.apple.Safari"; ctx.browserURL = "https://arxiv.org/abs/2211.17192"
        m.context = ctx
        var t1 = Turn(ask: "what is this paper about", app: "Safari", appLabel: ctx.label, bundleID: ctx.bundleID, voice: false)
        t1.answer = "It introduces **speculative decoding**: a small draft model proposes several tokens and the large model checks them in one pass, so output is identical but arrives 2–3× faster."
        t1.workedFor = 0.9
        var t2 = Turn(ask: "isko simple mein samjhao", app: "Safari", appLabel: ctx.label, bundleID: ctx.bundleID, voice: true)
        t2.answer = "Ek chhota model pehle guess karta hai, bada model sirf check karta hai, isliye jawab jaldi aata hai."
        t2.workedFor = 1.4
        let thread = Chat(turns: [t1, t2])

        func scene(_ name: String, _ setup: () -> Void) {
            m.chats = [Chat()]; m.chatIndex = 0; m.input = .voice; m.draft = ""; m.overlay = .none
            m.listening = false; m.partial = ""; m.busy = false; m.steps = []; m.selection = 0; m.filter = ""
            setup()
            var h: CGFloat = 0
            save(PanelView(onHeight: { h = $0 }).environmentObject(m), width: Grid.panelWidth, name: name, dir: dir, height: { h })
        }
        scene("1-idle") {}
        scene("2-typed-empty") { m.input = .typed }
        scene("3-typing") { m.input = .typed; m.draft = "what does the second paragraph say about latency" }
        scene("4-listening") { m.listening = true; m.partial = "close this tab" }
        scene("5-thread") { m.chats = [thread, Chat(turns: [t1])]; m.chatIndex = 0 }
        scene("6-thread-typing") { m.chats = [thread]; m.input = .typed; m.draft = "and the downsides?" }
        m.chats = [thread]; m.chatIndex = 0; m.overlay = .actions; m.selection = 1; m.filter = ""
        var ph: CGFloat = 0
        save(ActionsPopover(onHeight: { ph = $0 }).environmentObject(m), width: Grid.popoverWidth, name: "7-popover", dir: dir, height: { ph })
        m.filter = "chat"
        save(ActionsPopover(onHeight: { ph = $0 }).environmentObject(m), width: Grid.popoverWidth, name: "8-popover-search", dir: dir, height: { ph })
        save(SettingsView {}, width: 440, name: "9-settings", dir: dir, height: { 0 })

        // Height must follow content both ways: long thread → new empty chat → back (⌘[).
        m.overlay = .none; m.filter = ""
        var long = thread; for _ in 0..<4 { long.turns += thread.turns }
        m.chats = [long]; m.chatIndex = 0
        var heights: [CGFloat] = []
        let host = NSHostingView(rootView: PanelView(onHeight: { heights.append($0) }).environmentObject(m))
        let win = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: Grid.panelWidth, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        func settle(_ label: String) {
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
            print(String(format: "height after %@: %.0f", label, heights.last ?? -1))
        }
        settle("long thread")
        m.chats.append(Chat()); m.chatIndex = 1; settle("new empty chat")
        m.chatIndex = 0; settle("back to the long chat")
        m.chats = [Chat(turns: [t1])]; m.chatIndex = 0; settle("short chat")
        m.chats = [long]; m.chatIndex = 0; settle("long chat again")
        m.chats.append(Chat()); m.chatIndex = 1; settle("reopened after 2 min (new chat), want 56")
        print("chat position on the new empty chat: \(m.chatPosition ?? "none")")
    }

    private static func save<V: View>(_ view: V, width: CGFloat, name: String, dir: URL, height: () -> CGFloat) {
        let host = NSHostingView(rootView: view)
        let win = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        win.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)   // stand-in for the desktop behind the glass
        win.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
        let h = height() > 0 ? height() : host.fittingSize.height
        win.setContentSize(NSSize(width: width, height: h)); host.frame = NSRect(x: 0, y: 0, width: width, height: h)
        for _ in 0..<2 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(h * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: width, height: h)
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(String(format: "%@  %.0f×%.0f pt", url.lastPathComponent, width, h))
    }
}
