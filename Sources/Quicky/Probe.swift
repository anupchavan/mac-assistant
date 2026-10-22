import AppKit
import Foundation
import SwiftUI

/// Command-line checks against the real APIs, run from the built binary:
///   Quicky --probe keys
///   Quicky --probe chat "what is 2+2"          (sarvam-105b, prints TTFT)
///   Quicky --probe agent "open google.com" [v1] (agent route request; v1 = sarvam-105b instead of gemma4)
///   Quicky --probe vision                      (front window → gemma4 on /v2; tells you if V2 is whitelisted)
///   Quicky --probe context                     (prints the context block for the front app)
///   Quicky --probe tts "namaste" [hi-IN]       (Bulbul socket, plays it, prints first-audio latency)
///   Quicky --probe stt [seconds] [sarvam|deepgram] (records from the mic, realtime STT, prints the transcript)
///   Quicky --probe stt-ws "text" [rounds] [-v] (same TTS audio through Sarvam and Deepgram; final-transcript latency)
///   Quicky --probe route "block this user"
///   Quicky --probe controls [seconds]          (after a delay, lists the front window's CONTROLS and how long reading them took)
///   Quicky --probe selection [seconds]         (after a delay, reads the front app's selected text: accessibility, then ⌘C fallback)
///   Quicky --probe pick 4 "unfollow them|join" [models…] (which control each model would press; never runs it)
///   Quicky --probe reflex "close this tab"     (the no-model fast path: prints the tool call it would make, never runs it)
///   Quicky --probe handoff "block this user"   (computer-use instruction only; never clicks)
///   Quicky --probe render <dir>                (offscreen PNGs of the panel states; nothing appears on screen)
///   Quicky --probe settings <dir>              (opens the real Settings window, screenshots each tab, prints sizes)
///   Quicky --probe gesture                     (replays fn timelines through the state machine)
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
        case "controls":
            let wait = Double(rest.first ?? "3") ?? 3
            print("switch to the app to read; reading in \(wait) s…")
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            let t0 = Date()
            let cs = await Controls.harvest(pid: app.processIdentifier)
            print("\(app.localizedName ?? "?"): \(cs.count) controls in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            print(Controls.lines(cs, max: 200))
        case "selection":
            let wait = Double(rest.first ?? "3") ?? 3
            print("select some text in another app; reading in \(wait) s…")
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            var ctx = ScreenContext()
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            ctx.pid = app.processIdentifier
            let t0 = Date()
            ContextCapture.readAX(&ctx)
            print("focused: \(ctx.focused.isEmpty ? "none" : String(ctx.focused.prefix(80)))")
            print("\(app.localizedName ?? "?"): accessibility \(ctx.selectionUnreadable ? "can't read the selection" : "“\(ctx.selection.prefix(200))”") (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
            if ctx.selectionUnreadable {
                let s = await Selection.viaClipboard(pid: ctx.pid)
                print("clipboard: \(s.map { "“\($0.prefix(200))”" } ?? "nothing copied")")
            }
        case "reflex":
            AppIndex.load()
            let ask = rest.joined(separator: " ")
            let t0 = Date()
            let r = Reflex.match(ask)
            let us = Date().timeIntervalSince(t0) * 1_000_000
            if let r { print("\(r.label): \(r.calls.map { "\($0.name) \($0.arguments)" }.joined(separator: "; ")) → “\(r.reply)” (\(Int(us)) µs)") }
            else { print("no reflex; goes to the model (\(Int(us)) µs)") }
        case "chat":
            let q = rest.first ?? "Say hello in Hindi in five words."
            let t0 = Date()
            var first: Date?
            for try await e in SarvamChat.stream(model: Gemini.answerModel, version: .v1,
                                                 messages: [["role": "system", "content": Prompts.system], ["role": "user", "content": "OUTPUT_MODE: typed\n\nASK: \(q)"]],
                                                 reasoning: nil, maxTokens: 600) {
                if case let .text(t) = e { if first == nil { first = Date() }; print(t, terminator: ""); fflush(stdout) }
            }
            print(String(format: "\n— TTFT %.0f ms, total %.0f ms", ((first ?? Date()).timeIntervalSince(t0)) * 1000, Date().timeIntervalSince(t0) * 1000))
        case "pick":
            // Which control would each model press? One capture of the front window, the same agent-route
            // context the app sends, every model asked every ask. Prints tool calls; never runs them.
            // Quicky --probe pick 4 "unfollow them|join this" sarvam-105b gemini-3.5-flash
            let wait = Double(rest.first ?? "4") ?? 4
            let asks = (rest.dropFirst().first ?? "follow them").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let models = rest.count > 2 ? Array(rest.dropFirst(2)) : ["sarvam-105b", Gemini.answerModel]
            print("switch to the page; capturing in \(wait) s…")
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            let ctx = await ContextCapture.capture()
            print("\(ctx.appName) · \(ctx.browserURL) · \(ctx.controls.count) controls")
            let block = ctx.block(language: nil, outputMode: "voice", includeOCR: false, includeLinks: true)
            for ask in asks {
                print("\n“\(ask)”")
                for model in models {
                    let messages: [[String: Any]] = [["role": "system", "content": Prompts.system],
                                                     ["role": "user", "content": block + "\n\nASK: \(ask)"]]
                    var calls: [Int: (name: String, args: String)] = [:]
                    var text = ""
                    let t0 = Date()
                    do {
                        for try await e in SarvamChat.stream(model: model, version: .v1, messages: messages,
                                                             tools: Tools.declarations, reasoning: nil, maxTokens: 400) {
                            switch e {
                            case .text(let t): text += t
                            case .toolCallDelta(let i, _, let name, let args):
                                var c = calls[i] ?? ("", ""); c.name += name ?? ""; c.args += args ?? ""; calls[i] = c
                            default: break
                            }
                        }
                    } catch { print("  \(model): error \(error.localizedDescription)"); continue }
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    let shown = calls.keys.sorted().map { i -> String in
                        let c = calls[i]!
                        if c.name == "press", let d = c.args.data(using: .utf8),
                           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                           let id = (j["id"] as? NSNumber)?.intValue, let ctl = ctx.controls.first(where: { $0.id == id }) {
                            return "press → \(ctl.line)" + (Controls.notSetReply(ask: ask, label: ctl.label).map { " (refused: “\($0)”)" } ?? "")
                        }
                        return "\(c.name) \(c.args)"
                    }
                    print("  \(model) (\(ms) ms): \(shown.isEmpty ? "said “\(text.prefix(120))”" : shown.joined(separator: "; "))")
                }
            }
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
        case "settings":
            let dir = rest.first ?? NSTemporaryDirectory()
            let settings = await MainActor.run { () -> SettingsWindow in let s = SettingsWindow(); s.show(); return s }
            for i in 0..<2 {
                let (num, info) = await MainActor.run { () -> (Int, String) in
                    let w = settings.window!
                    (w.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = i
                    return (w.windowNumber, "tab \(i): title \"\(w.title)\", frame \(Int(w.frame.width))×\(Int(w.frame.height))")
                }
                try await Task.sleep(nanoseconds: 600_000_000)
                print(info)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l\(num)", "\(dir)/settings-tab\(i).png"]
                try p.run(); p.waitUntilExit()
            }
            await MainActor.run { settings.window?.close() }
        case "render":
            // Draws the real panel views with fixture state into windows that are never shown, and saves PNGs (2x).
            let dir = URL(fileURLWithPath: rest.first ?? NSTemporaryDirectory())
            await MainActor.run { RenderProbe.run(into: dir) }
        case "stt-ws":
            // Speech made by Sarvam TTS (REST, 16 kHz) streamed into our realtime STT socket like the mic would.
            SarvamSTT.debug = true; DeepgramSTT.debug = rest.contains("-v")
            let text = rest.first ?? "Can you close this tab?"
            var req = URLRequest(url: Sarvam.base.appendingPathComponent("text-to-speech"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(try Sarvam.key(), forHTTPHeaderField: "api-subscription-key")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "target_language_code": "en-IN", "model": "bulbul:v3",
                                                                       "speaker": "shubh", "speech_sample_rate": 16000])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let b64 = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["audios"] as? [String], let first = b64.first,
                  var pcm = Data(base64Encoded: first) else { print("tts failed: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"); return }
            if pcm.prefix(4) == "RIFF".data(using: .ascii)! { pcm = pcm.subdata(in: 44..<pcm.count) }
            print("speech: \(pcm.count / 32000) s")
            // Same audio through every provider with a key, a few rounds each, so the numbers compare.
            var providers: [STT.Provider] = [.sarvam]
            if Keys.deepgram != nil { providers.append(.deepgram) }
            let rounds = Int(rest.dropFirst().first ?? "3") ?? 3
            for p in providers {
                var times: [Double] = []
                for _ in 0..<rounds {
                    let stt = STT.make(p)
                    stt.connect()       // no wait: audio starts before the handshake, as with the mic
                    var i = 0
                    while i < pcm.count { stt.send(pcm.subdata(in: i..<min(i + 3200, pcm.count))); i += 3200; try await Task.sleep(nanoseconds: 100_000_000) }
                    let t0 = Date()
                    let (heard, lang) = await stt.finish(timeout: 3)
                    let ms = Date().timeIntervalSince(t0) * 1000
                    times.append(ms)
                    print(String(format: "%@ final after %.0f ms: \"%@\" (%@)", p.rawValue, ms, heard, lang ?? "?"))
                }
                print(String(format: "%@ median %.0f ms", p.rawValue, times.sorted()[times.count / 2]))
            }
        case "audio-devices":
            print("default input is Bluetooth: \(AudioDevices.defaultInputIsBluetooth); built-in mic found: \(AudioDevices.builtInInput != nil) → recording from \(AudioDevices.defaultInputIsBluetooth && AudioDevices.builtInInput != nil ? "the built-in mic" : "the default input")")
        case "tts-dump":
            // Raw Bulbul stream, no playback: chunk sizes, headers, odd lengths, arrival vs audio time.
            let text = rest.first ?? "Speculative decoding uses a small draft model to propose several tokens, and the large model checks them all in one pass. The output is identical, but it arrives two to three times faster, which matters a lot for voice assistants like this one."
            let tts = SarvamTTS(language: "en-IN")
            let t0 = Date()
            let done = DispatchSemaphore(value: 0)
            var chunks: [(at: Double, data: Data)] = []
            tts.onAudio = { chunks.append((Date().timeIntervalSince(t0), $0)) }
            tts.onFinal = { done.signal() }
            tts.onError = { print("tts error: \($0)"); done.signal() }
            try tts.connect()
            // Sentence by sentence, as the app feeds it while the answer streams.
            for sentence in text.components(separatedBy: ". ") { tts.speak(sentence.hasSuffix(".") ? sentence : sentence + "."); try await Task.sleep(nanoseconds: 150_000_000) }
            tts.flush()
            _ = await withCheckedContinuation { c in DispatchQueue.global().async { c.resume(returning: done.wait(timeout: .now() + 30)) } }
            tts.close()
            var audioEnd = 0.0, firstAt = chunks.first?.at ?? 0, underruns = 0
            var all = Data()
            for (i, c) in chunks.enumerated() {
                let riff = c.data.prefix(4) == "RIFF".data(using: .ascii)!
                var pcm = c.data; if riff { pcm = pcm.subdata(in: 44..<pcm.count) }
                let dur = Double(pcm.count / 2) / 22050
                // Playback would start at the first chunk; a chunk arriving after the audio so far has finished is an underrun.
                let playClock = c.at - firstAt
                if i > 0 && playClock > audioEnd { underruns += 1 }
                audioEnd = max(audioEnd, playClock) + (i == 0 ? dur : 0) + (i > 0 ? dur : 0)
                if i < 40 { print(String(format: "#%02d at %5.2fs bytes %6d%@%@ dur %.2fs  audio-ahead %.2fs", i, c.at, c.data.count, riff ? " RIFF" : "", c.data.count % 2 == 1 ? " ODD" : "", dur, audioEnd - playClock)) }
                all.append(pcm)
            }
            print("chunks \(chunks.count), odd-length \(chunks.filter { $0.data.count % 2 == 1 }.count), with RIFF header \(chunks.filter { $0.data.prefix(4) == "RIFF".data(using: .ascii)! }.count), underruns \(underruns)")
            if let out = rest.dropFirst().first { try Microphone.wav(all, sampleRate: 22050).write(to: URL(fileURLWithPath: out)); print("wrote \(out)") }
            if let out = rest.dropFirst().first {
                try chunks.map { String($0.data.count) }.joined(separator: "\n").write(toFile: out + ".sizes", atomically: true, encoding: .utf8)
                try chunks.map { $0.data.prefix(16).map { String(format: "%02x", $0) }.joined() }.joined(separator: "\n").write(toFile: out + ".heads", atomically: true, encoding: .utf8)
            }
        case "stress":
            // Usage: stress <data-dir> [runs] [screenshot.jpg]. Real app pipeline (system prompt, tools, context block,
            // screenshot for the vision model) with preloaded "memory" from the .md/.txt files in <data-dir> at growing
            // sizes, plus a recent chat history at the bigger sizes. A fact (the needle) sits in the middle of the memory.
            // Per size: first run (cold) and the rest (same prefix, so prefix caching can help), and whether the needle
            // was recalled. Sizes are approximate tokens (chars / 4).
            guard let dir = rest.first else { print("usage: stress <data-dir> [runs] [image]"); return }
            let runs = Int(rest.dropFirst().first ?? "3") ?? 3
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".md") || $0.hasSuffix(".txt") }.sorted()
            let corpus = files.compactMap { f in (try? String(contentsOfFile: dir + "/" + f, encoding: .utf8)).map { "## Document: \(f)\n\n\($0)" } }.joined(separator: "\n\n")
            guard !corpus.isEmpty else { print("no .md/.txt files in \(dir)"); return }
            let needle = "Dentist: Anup's appointment with Dr. Kavita Mehta is on Thursday 6 November at 4:40 pm, at the Banjara Hills clinic."
            let profile = """
            **Work context**

            Anup is a student and builder in India working on Quicky, a native Swift voice assistant for the Mac, on Sarvam's speech and language models. He also builds Obsidian plugins, a handwriting font (Cyanide) and course assignments in compilers and machine learning.

            **Personal context**

            Prefers short, direct answers, Hinglish is fine. Works late at night. Uses Zed, Safari, Obsidian and Claude daily.

            """
            /// `tokens` of memory: profile, then real documents (repeated if needed) with the needle in the middle.
            func memory(_ tokens: Int) -> String {
                guard tokens > 0 else { return "" }
                var body = ""
                var round = 0
                while body.count < tokens * 4 { round += 1; body += (round > 1 ? "\n\n(Archive copy \(round))\n\n" : "") + corpus }
                body = String(body.prefix(tokens * 4))
                let mid = body.index(body.startIndex, offsetBy: body.count / 2)
                let cut = body[mid...].firstIndex(of: "\n") ?? mid
                return "MEMORY (what you know about the user and their work; use it when relevant):\n\n" + profile
                    + String(body[..<cut]) + "\n\n" + needle + "\n" + String(body[cut...])
            }
            /// Ten earlier turns cut from the corpus, like a long-running chat.
            let history: [[String: Any]] = (0..<10).flatMap { i -> [[String: Any]] in
                let start = corpus.index(corpus.startIndex, offsetBy: (i * 2_400) % max(1, corpus.count - 2_400))
                let chunk = String(corpus[start...].prefix(2_000))
                return [["role": "user", "content": "Explain this part of the plan: \(chunk.prefix(300))"], ["role": "assistant", "content": chunk]]
            }
            let image = rest.dropFirst(2).first.flatMap { CGImageSourceCreateWithURL(URL(fileURLWithPath: $0) as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            let shotURL = image.flatMap { ContextCapture.jpegDataURL($0) }
            var ctx = ScreenContext()
            ctx.appName = "Safari"; ctx.bundleID = "com.apple.Safari"; ctx.windowTitle = "Sarvam AI dashboard"
            let block = ctx.block(language: nil, outputMode: "voice", includeOCR: false)
                        let sizes = (ProcessInfo.processInfo.environment["STRESS_SIZES"] ?? "0,3000,8000,32000,100000").split(separator: ",").compactMap { Int($0) }
            print("Sarvam, \(files.count) files (\(corpus.count / 4) tokens of text), \(runs) runs per size, tools \(Tools.declarations.count)")
            print("model|memory_tokens|history|cold_ttft_ms|warm_ttft_med_ms|total_med_ms|needle|fails")
            for (model, version, vision) in [(Keys.setting("ASSISTANT_DEEP_MODEL", default: "sarvam-105b"), SarvamChat.Version.v1, false), (Keys.setting("ASSISTANT_VISION_MODEL", default: "gemma4"), SarvamChat.Version.v2, true)] {
                if vision && shotURL == nil { continue }
                for size in sizes {
                    let system = Prompts.system + (size > 0 ? "\n\n" + memory(size) : "")
                    let hist = size >= 8_000 ? history : []
                    var ttfts: [Double] = [], totals: [Double] = [], recalled = 0, fails = 0, lastError = ""
                    for r in 0..<runs {
                        let ask = r % 2 == 0 ? "when is my dentist appointment and with whom?" : "what's on my screen, in one line?"
                        let user: Any = vision
                            ? [["type": "text", "text": block], ["type": "image_url", "image_url": ["url": shotURL!]], ["type": "text", "text": "ASK: \(ask)"]] as [[String: Any]]
                            : block + "\n\nASK: \(ask)"
                        let messages = [["role": "system", "content": system]] + hist + [["role": "user", "content": user]]
                        for attempt in 0..<4 {
                            let t0 = Date(); var first: Date?; var out = ""
                            do {
                                for try await e in SarvamChat.stream(model: model, version: version, messages: messages, tools: Tools.declarations, reasoning: nil, maxTokens: 200) {
                                    if case let .text(t) = e, !t.isEmpty { if first == nil { first = Date() }; out += t }
                                    if case let .toolCallDelta(_, _, name, args) = e { out += "[tool \(name ?? "")\(args ?? "")]" }
                                }
                                if ProcessInfo.processInfo.environment["STRESS_VERBOSE"] != nil { print("  \(model) \(size) r\(r): \(out.prefix(160).replacingOccurrences(of: "\n", with: " "))") }
                            } catch let e as APIError where e.status == 429 && attempt < 3 {
                                try await Task.sleep(nanoseconds: UInt64(8 + attempt * 8) * 1_000_000_000); continue
                            } catch { fails += 1; lastError = (error as? APIError)?.sanitizedMessage ?? error.localizedDescription; break }
                            if let first { ttfts.append(first.timeIntervalSince(t0) * 1000); totals.append(Date().timeIntervalSince(t0) * 1000) } else { fails += 1; lastError = "no text" }
                            if r % 2 == 0, out.contains("4:40") || out.lowercased().contains("mehta") { recalled += 1 }
                            break
                        }
                        if vision { try await Task.sleep(nanoseconds: 2_500_000_000) }   // V2 rate limit
                    }
                    func med(_ a: [Double]) -> String { a.isEmpty ? "-" : String(format: "%.0f", a.sorted()[a.count / 2]) }
                    let needleAsks = (runs + 1) / 2
                    print("\(model)\(vision ? "+shot" : "")|\(size)|\(hist.count / 2)|\(ttfts.first.map { String(format: "%.0f", $0) } ?? "-")|\(med(Array(ttfts.dropFirst())))|\(med(totals))|\(size == 0 ? "n/a" : "\(recalled)/\(needleAsks)")|\(fails)\(lastError.isEmpty ? "" : " (\(lastError))")")
                }
            }
        case "prompt-bench":
            // Same pipeline (context block + screenshot for gemma4, reasoning off); only the system prompt differs.
            // Usage: prompt-bench <other-system-prompt-file> [runs] [image.png]. "{model}" and "{date}" are filled in.
            // The two prompts alternate request by request, and 429s back off and retry, so neither side gets the
            // quiet half of the rate limit.
            guard let file = rest.first, let other = try? String(contentsOfFile: file, encoding: .utf8) else { print("usage: prompt-bench <prompt-file> [runs] [image]"); return }
            let runs = Int(rest.dropFirst().first ?? "3") ?? 3
            var ctx = ScreenContext()
            ctx.appName = "Safari"; ctx.bundleID = "com.apple.Safari"; ctx.windowTitle = "Speculative decoding explained"
            ctx.browserURL = "https://arxiv.org/abs/2211.17192"
            ctx.visibleText = "Fast Inference from Transformers via Speculative Decoding. Abstract: Inference from large autoregressive models like Transformers is slow - decoding K tokens takes K serial runs of the model. In this work we introduce speculative decoding - an algorithm to sample from autoregressive models faster without any changes to the outputs, by computing several tokens in parallel."
            let image = rest.dropFirst(2).first.flatMap { CGImageSourceCreateWithURL(URL(fileURLWithPath: $0) as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            let shotURL = image.flatMap { ContextCapture.jpegDataURL($0) }
            let asks = ["what is this page about", "summarise what I'm looking at in one line", "what should I do next here"]
            let date = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
            print("fixed context (\(ctx.appName)), screenshot \(shotURL == nil ? "no" : "yes"); \(asks.count) asks × \(runs) runs per cell")
            struct Cell { var ttft: [Double] = [], total: [Double] = [], chars: [Int] = [], fails = 0, retries = 0 }
            var cells: [String: Cell] = [:]
            let models = [(Keys.setting("ASSISTANT_DEEP_MODEL", default: "sarvam-105b"), SarvamChat.Version.v1),
                          (Keys.setting("ASSISTANT_VISION_MODEL", default: "gemma4"), SarvamChat.Version.v2)]
            for (model, version) in models {
                for r in 0..<(runs * asks.count) {
                    let ask = asks[r % asks.count]
                    // Alternate which prompt goes first each round.
                    let order = r % 2 == 0 ? ["ours", "raycast"] : ["raycast", "ours"]
                    for label in order {
                        let system = label == "ours" ? Prompts.system : other.replacingOccurrences(of: "{model}", with: model).replacingOccurrences(of: "{date}", with: date)
                        let text = ctx.block(language: nil, outputMode: "typed", includeOCR: false)
                        let user: Any = version == .v2 && shotURL != nil
                            ? [["type": "text", "text": text], ["type": "image_url", "image_url": ["url": shotURL!]], ["type": "text", "text": "ASK: \(ask)"]] as [[String: Any]]
                            : text + "\n\nASK: \(ask)"
                        let key = "\(model)|\(label)"
                        var cell = cells[key] ?? Cell()
                        for attempt in 0..<4 {
                            let t0 = Date(); var first: Date?; var out = ""
                            do {
                                for try await e in SarvamChat.stream(model: model, version: version, messages: [["role": "system", "content": system], ["role": "user", "content": user]],
                                                                     reasoning: nil, maxTokens: 900) {
                                    if case let .text(t) = e, !t.isEmpty { if first == nil { first = Date() }; out += t }
                                }
                            } catch let e as APIError where e.status == 429 && attempt < 3 {
                                cell.retries += 1; try await Task.sleep(nanoseconds: UInt64(8 + attempt * 8) * 1_000_000_000); continue
                            } catch { cell.fails += 1; print("  fail (\(label), \(model)): \((error as? APIError)?.sanitizedMessage ?? error.localizedDescription)"); break }
                            if let first {
                                cell.ttft.append(first.timeIntervalSince(t0) * 1000); cell.total.append(Date().timeIntervalSince(t0) * 1000); cell.chars.append(out.count)
                            } else { cell.fails += 1 }
                            break
                        }
                        cells[key] = cell
                        if version == .v2 { try await Task.sleep(nanoseconds: 2_500_000_000) }   // stay under the V2 rate limit
                    }
                }
            }
            func med(_ a: [Double]) -> Double { a.isEmpty ? .nan : a.sorted()[a.count / 2] }
            func p90(_ a: [Double]) -> Double { a.isEmpty ? .nan : a.sorted()[min(a.count - 1, Int(Double(a.count) * 0.9))] }
            for (model, _) in models { for label in ["ours", "raycast"] {
                let c = cells["\(model)|\(label)"] ?? Cell()
                print(String(format: "RESULT|%@|%@|%.0f|%.0f|%.0f|%d|%d|%d|%d", model, label, med(c.ttft), p90(c.ttft), med(c.total),
                             c.chars.isEmpty ? 0 : c.chars.reduce(0, +) / c.chars.count, c.ttft.count, c.fails, c.retries))
            } }
        case "media-test":
            // Two synthetic 4 s clips → keep 0–2.5 of the first + all of the second → expect 6.5 s.
            let dir = URL(fileURLWithPath: rest.first ?? NSTemporaryDirectory())
            let a = dir.appendingPathComponent("clip-a.mov"), b = dir.appendingPathComponent("clip-b.mov")
            try await MediaTestClips.write(a, seconds: 4, gray: 0.2); try await MediaTestClips.write(b, seconds: 4, gray: 0.8)
            let r = try await Media.trimAndMerge([Media.Clip(url: a, start: nil, end: Media.seconds("0:02.5") ?? 2.5),
                                                  Media.Clip(url: b, start: nil, end: nil)], output: dir.appendingPathComponent("merged.mov"))
            let d = try await AVURLAsset(url: r.url).load(.duration).seconds
            print(String(format: "merged %@: composed %.2f s, file %.2f s", r.url.lastPathComponent, r.seconds, d))
        case "agent-fixture":
            // The user's real ask against a fixed Finder context, to see which tool the model picks (never run).
            let ask = rest.first ?? "from the one which was recorded earlier, keep like 09:35 and from the second, complete keep, and merge both videos into one (one after other)"
            let block = """
            APP: Finder (com.apple.finder)
            WINDOW: Downloads
            FINDER_SELECTION: /Users/me/Downloads/Screen Recording 2026-10-16 at 10.17.16 PM.mov
            /Users/me/Downloads/Screen Recording 2026-10-16 at 10.30.28 PM.mov
            OUTPUT_MODE: typed
            """
            for (model, version) in [(Keys.setting("ASSISTANT_DEEP_MODEL", default: "sarvam-105b"), SarvamChat.Version.v1)] {
                var name = "", args = ""
                for try await e in SarvamChat.stream(model: model, version: version, messages: [["role": "system", "content": Prompts.system], ["role": "user", "content": block + "\n\nASK: \(ask)"]],
                                                     tools: Tools.declarations, reasoning: nil, maxTokens: 600) {
                    if case let .toolCallDelta(_, _, n, a) = e { name += n ?? ""; args += a ?? "" }
                    if case let .text(t) = e { print(t, terminator: "") }
                }
                print("\n\(model): \(name.isEmpty ? "no tool" : name) \(args)")
            }
        case "cua-plan":
            // The first real computer-use step for a task on the front window, never executed. Screenshot
            // requests are answered (harmless) until the model plans something else; that is printed with
            // where it would land on screen and the accessibility label there.
            guard let key = Keys.openAI else { print("OpenAI key: missing"); return }
            let ctx = await ContextCapture.capture()
            guard let first = await ContextCapture.screenshot(pid: ctx.pid), let url = ContextCapture.pngDataURL(first.0) else { print("no screenshot"); return }
            let task = rest.first ?? "Block the user whose profile is open"
            let model = Keys.setting("ASSISTANT_CUA_MODEL", default: "gpt-6-astra")
            print("window \(ctx.appName) frame \(first.1), image \(first.0.width)×\(first.0.height)")
            var body: [String: Any] = ["model": model, "tools": [["type": "computer"]], "reasoning": ["effort": "low"],
                                       "instructions": Prompts.astraInstructions, "truncation": "auto",
                                       "input": [["role": "user", "content": [["type": "input_text", "text": task],
                                                  ["type": "input_image", "image_url": url, "detail": "original"]]]]]
            let t0 = Date()
            rounds: for round in 1...4 {
                let r: [String: Any]
                do { r = try await ComputerUser.post(body, key: key) } catch let e as APIError { print("HTTP \(e.status), \(e.sanitizedMessage)"); return }
                var outputs: [[String: Any]] = []
                for item in r["output"] as? [[String: Any]] ?? [] {
                    let type = item["type"] as? String ?? "?"
                    if type == "message" {
                        print("  round \(round) message: \((item["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined().prefix(300) ?? "")")
                    } else if type == "computer_call" {
                        let acts = (item["actions"] as? [[String: Any]]) ?? (item["action"] as? [String: Any]).map { [$0] } ?? []
                        let real = acts.filter { ($0["type"] as? String) != "screenshot" }
                        if !real.isEmpty {
                            for a in real {
                                let x = (a["x"] as? NSNumber)?.doubleValue ?? -1, y = (a["y"] as? NSNumber)?.doubleValue ?? -1
                                let p = ComputerUser.map(x, y, windowFrame: first.1, imageSize: CGSize(width: first.0.width, height: first.0.height))
                                print("  round \(round) would do: \(a["type"] ?? "?") at image (\(Int(x)), \(Int(y))) → screen \(p.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "outside window"), target label: \(p.flatMap { ComputerUser.label(at: $0) } ?? "none")")
                            }
                            break rounds
                        }
                        print("  round \(round): screenshot requested")
                        outputs.append(["type": "computer_call_output", "call_id": item["call_id"] as? String ?? "",
                                        "output": ["type": "computer_screenshot", "image_url": url, "detail": "original"]])
                    }
                }
                guard !outputs.isEmpty, let id = r["id"] as? String else { break }
                body["previous_response_id"] = id
                body["input"] = outputs
            }
            print(String(format: "— %.0f ms, nothing executed", Date().timeIntervalSince(t0) * 1000))
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
            let stt = STT.make(rest.dropFirst().first.flatMap(STT.Provider.init(rawValue:)) ?? STT.provider)
            stt.onPartial = { print("… \($0)") }
            stt.onError = { print("stt error: \($0)") }
            stt.connect()
            mic.onChunk = { chunk, _ in stt.send(chunk) }
            try mic.start()
            print("speak now for \(Int(secs))s")
            try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
            mic.stop()
            let t0 = Date()
            let (text, lang) = await stt.finish(timeout: 3)
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
        // The ⌘K card exactly as the app wraps it (masked blur container), to catch layout bugs in the wrapper.
        let wrapped = NSHostingView(rootView: ActionsPopover(onHeight: { _ in }).environmentObject(m))
        wrapped.sizingOptions = []
        let card = PanelController.glass(around: wrapped, radius: Grid.popoverRadius, liquid: false)
        let cw = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: Grid.popoverWidth, height: ph), styleMask: .borderless, backing: .buffered, defer: false)
        cw.contentView = card
        for _ in 0..<3 { card.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
        print("wrapped card: content \(Int(wrapped.frame.width))×\(Int(wrapped.frame.height)) in window \(Int(ph))")
        m.filter = "chat"
        save(ActionsPopover(onHeight: { ph = $0 }).environmentObject(m), width: Grid.popoverWidth, name: "8-popover-search", dir: dir, height: { ph })
        save(GeneralSettings(), width: SettingsWindow.size.width, name: "9-settings-general", dir: dir, height: { SettingsWindow.size.height })
        save(KeysSettings(), width: SettingsWindow.size.width, name: "9-settings-keys", dir: dir, height: { SettingsWindow.size.height })
        save(AgentCursor.preview(label: "Clicking Block @elonmusk"), width: 220, name: "10-agent-cursor", dir: dir, height: { 44 })

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

import AVFoundation
import CoreVideo

/// Solid-grey test clips for `--probe media-test`.
enum MediaTestClips {
    static func write(_ url: URL, seconds: Int, gray: CGFloat) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
        for f in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            memset(CVPixelBufferGetBaseAddress(pb), Int32(gray * 255), CVPixelBufferGetDataSize(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 10))
        }
        input.markAsFinished()
        await w.finishWriting()
    }
}
