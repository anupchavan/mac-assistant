import AppKit
import SwiftUI

struct StatusStep: Identifiable, Equatable {
    enum State { case active, done, error }
    let id = UUID()
    var title: String
    var state: State
    var started = Date()
}

struct ActionItem: Identifiable {
    let id = UUID()
    var section = "Chat"
    let title: String
    let icon: String
    let keys: [String]
    let perform: () -> Void
}

/// Set while we move focus to another app ourselves (app switcher, insert), so the resulting
/// app activation isn't read as the user leaving.
@MainActor
enum FocusMove {
    static var until = Date.distantPast
    static func begin(_ seconds: TimeInterval = 1.5) { until = Date().addingTimeInterval(seconds) }
    static var active: Bool { Date() < until }
}

/// The whole panel's state and the voice → context → model → voice pipeline.
@MainActor
final class AppModel: ObservableObject {
    enum InputMode { case voice, typed }
    enum Overlay: Equatable { case none, actions, chats, apps, confirm }

    // Panel
    @Published var visible = false
    @Published var input: InputMode = .voice
    @Published var listening = false
    @Published var handsFree = false
    @Published var partial = ""
    @Published var draft = ""
    @Published var overlay: Overlay = .none
    @Published var selection = 0
    @Published var filter = ""
    @Published var follow = true
    @Published var focusField = false
    @Published var panelCap: CGFloat = 560

    // Work
    @Published var busy = false
    @Published var speaking = false
    @Published var steps: [StatusStep] = []
    @Published var answerStarted = false
    @Published var context: ScreenContext?
    @Published var pendingTool: ToolCall?
    @Published var pendingComputer: ComputerUser.Handoff?
    @Published var cuaStatus: String?
    @Published var notice: String?

    // Chats
    @Published var chats: [Chat]
    @Published var chatIndex: Int
    private var lastUsed = Date.distantPast

    weak var controller: PanelController?
    let hotkey = HotkeyMonitor()

    private let mic = Microphone()
    private var stt: SarvamSTT?
    private var contextTask: Task<ScreenContext, Never>?
    private var contextAt = Date.distantPast
    private var turnTask: Task<Void, Never>?
    private var tts: SarvamTTS?
    private var player = PCMPlayer(sampleRate: 22050)
    private var ttsFinalReceived = false
    private var sentenceBuffer = ""
    private var spokenChars = 0          // answer characters handed to TTS
    private var shownBeforeHold = false
    private var confirmContinuation: CheckedContinuation<Bool, Never>?
    private var cua: ComputerUser?
    private var cuaUserTravel: Double = 0     // points the user has moved the mouse during computer use
    private var gate = SpeechGate()
    private var tapStoppedSpeech = false
    private var lastRetry: (() -> Void)?
    private var toolRanThisTurn = false     // never re-run a turn whose tool already acted
    private var visionAvailable: Bool {
        get { UserDefaults.standard.object(forKey: "visionAvailable") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "visionAvailable") }
    }

    init() {
        let loaded = ChatStore.load()
        let initial = loaded.isEmpty ? [Chat()] : loaded
        chats = initial
        chatIndex = initial.count - 1
        if let last = initial.last?.updatedAt { lastUsed = last }
        player.onDrained = { [weak self] in self?.playbackDrained() }
        hotkey.onGesture = { [weak self] g in self?.gesture(g) }
        hotkey.onEscape = { [weak self] in self?.escape() ?? false }
        hotkey.onUserMouse = { [weak self] dx, dy, clicked in self?.userMouse(dx: dx, dy: dy, clicked: clicked) }
    }

    var chat: Chat { chats.indices.contains(chatIndex) ? chats[chatIndex] : Chat() }
    var turns: [Turn] { chat.turns }
    var chatPosition: String? {
        // Only chats with turns count; an empty new chat shows no position.
        let real = chats.filter { !$0.turns.isEmpty }
        guard real.count > 1, !chat.turns.isEmpty, let i = real.firstIndex(where: { $0.id == chat.id }) else { return nil }
        return "\(i + 1) / \(real.count)"
    }
    var lastAnswerTyped: Bool { (turns.last.map { !$0.voice && !$0.answer.isEmpty }) ?? false }
    var idle: Bool { !listening && !busy && !speaking && overlay != .confirm && cua == nil }

    // MARK: - Gestures

    func gesture(_ g: FnGesture.Output) {
        switch g {
        case .preroll:
            tapStoppedSpeech = speaking
            if speaking { stopSpeaking() }
            guard cua == nil, overlay != .confirm else { return }
            if busy { turnTask?.cancel(); finishTurn(error: nil) }
            shownBeforeHold = visible
            prerollListening()
        case .holdBegan:
            beginListening(handsFree: false)
        case let .holdEnded(heldMs):
            if heldMs < 500 { discardPreroll(); if !shownBeforeHold { hide() } ; return }
            endListening()
        case .handsFree:
            if mic.running == false { prerollListening() }
            beginListening(handsFree: true)
        case .handsFreeStop:
            endListening()
        case .typed:
            // shift+fn / fn+Space toggles: opens typing, or closes the panel if it was already open.
            let wasOpen = listening ? shownBeforeHold : visible
            discardPreroll()
            if wasOpen { hotkey.resetGesture(); hide() } else { showTyped() }
        case .tap:
            if listening && handsFree { endListening() }
            else if !listening {
                discardPreroll()
                // A plain fn tap on an open, idle panel closes it (a tap that stopped speech only stops speech).
                if visible && !tapStoppedSpeech && !busy && overlay != .confirm && cua == nil { hide() }
            }
        case .cancel:
            cancelAll(); hide()
        case .discard:
            discardPreroll()
            if listening, !shownBeforeHold { hide() }
        }
    }

    /// Esc, one press: stops computer use, cancels the confirm card, closes a popover, or else closes
    /// the panel (stopping speech, listening and any answer in flight). Returns true when it acted.
    func escape() -> Bool {
        if let cua { cua.stop("you pressed Esc"); return true }
        if overlay == .confirm { resolveConfirm(false); return true }
        if overlay != .none { overlay = .none; return true }
        guard visible || listening || speaking || busy else { return false }
        hotkey.resetGesture()
        hide()
        return true
    }

    // MARK: - Showing

    /// Reopening within this long continues the chat; after it, a fresh one (⌘[ goes back).
    static let continueWindow: TimeInterval = 120

    private func prepareChat() {
        guard Date().timeIntervalSince(lastUsed) > Self.continueWindow else { return }
        if chats.last?.turns.isEmpty ?? true {
            if chats.isEmpty { chats.append(Chat()) }
        } else {
            chats.append(Chat())
        }
        chatIndex = chats.count - 1
    }

    func show() {
        if !visible { prepareChat() }
        visible = true
        notice = nil
        controller?.show()
    }

    func showTyped() {
        captureContext()
        input = .typed
        overlay = .none
        show()
        focusField = true
    }

    func hide() {
        if visible { lastUsed = Date() }     // the 2-minute window counts from when you last had it open
        cancelAll()
        visible = false
        overlay = .none
        controller?.hide()
    }

    /// Outside click, ⌘-Tab, another app activating, or the panel losing key: close (stopping speech and
    /// any answer in flight) unless listening, confirming, using the computer, or moving focus ourselves.
    /// The chat stays for the 5-minute continue rule.
    func dismissFromOutside(_ reason: String) {
        guard visible else { return }
        let keep = listening || overlay == .confirm || cua != nil || FocusMove.active
        Log.info("outside \(reason): listening=\(listening) busy=\(busy) speaking=\(speaking) follow=\(follow) overlay=\(overlay) cua=\(cua != nil) focusMove=\(FocusMove.active) → \(keep ? "stay" : "hide")")
        if !keep { hide() }
    }

    func cancelAll() {
        discardPreroll()
        if speaking { stopSpeaking() }
        turnTask?.cancel()
        if busy { finishTurn(error: nil) }
        resolveConfirm(false)
        cua?.stop("closed")
    }

    // MARK: - Context

    func captureContext() {
        let t = Task.detached(priority: .userInitiated) { await ContextCapture.capture() }
        contextTask = t
        contextAt = Date()
        Task { let c = await t.value; if self.contextTask == t { self.context = c } }
    }

    private func freshContext() async -> ScreenContext {
        if Date().timeIntervalSince(contextAt) > 4 || contextTask == nil { captureContext() }
        return await contextTask!.value
    }

    // MARK: - Listening

    private func prerollListening() {
        captureContext()
        let s = SarvamSTT()
        s.onPartial = { [weak self] text in self?.partial = text }
        s.onError = { [weak self] m in self?.notice = m }
        s.connect()
        stt = s
        partial = ""
        gate = SpeechGate()
        mic.onChunk = { [weak self, weak s] chunk, level in
            s?.send(chunk)
            Task { @MainActor in self?.level(level) }
        }
        do { try mic.start() } catch { notice = "Microphone unavailable: \(error.localizedDescription)" }
    }

    private func beginListening(handsFree hf: Bool) {
        listening = true
        handsFree = hf
        input = .voice
        overlay = .none
        show()
    }

    private func discardPreroll() {
        mic.stop()
        stt?.close()
        stt = nil
        listening = false
        handsFree = false
        partial = ""
    }

    /// Local silence detection for hands-free: stop after 0.5 s of silence once speech was heard
    /// (3 s if the words so far sound unfinished).
    /// Hands-free gives up after this long with no speech at all.
    private static let handsFreeNoSpeechSeconds: TimeInterval = 8

    private func level(_ rms: Float) {
        guard stt != nil else { return }
        if gate.feed(rms) { return }
        guard listening, handsFree else { return }
        guard gate.heardSpeech else {
            if Date().timeIntervalSince(mic.startedAt) > Self.handsFreeNoSpeechSeconds { hotkey.resetGesture(); endListening() }
            return
        }
        let unfinished = partial.range(of: #"(?i)\b(and|but|so|ki|toh|aur|ya|or|the)\s*$"#, options: .regularExpression) != nil
        if gate.silenceMs >= (unfinished ? 3000 : 800) { hotkey.resetGesture(); endListening() }
    }

    private func endListening() {
        guard let s = stt else { listening = false; return }
        let duration = Date().timeIntervalSince(mic.startedAt)
        mic.stop()
        listening = false
        handsFree = false
        stt = nil
        // Nothing was said: no STT call, no turn.
        if duration < 0.3 || !gate.heardSpeech {
            Log.info(String(format: "no speech (voiced %.0f ms, floor %.3f); discarded", gate.voicedMs, gate.noiseFloor))
            s.close(); partial = ""
            if !shownBeforeHold && turns.isEmpty { hide() }
            return
        }
        let voicedMs = gate.voicedMs
        busy = true
        steps = [StatusStep(title: "Listening", state: .active)]
        let t0 = Date()
        Task {
            let (text, lang) = await s.finish()
            Log.time("stt.final", since: t0)
            let ask = text.trimmingCharacters(in: .whitespacesAndNewlines)
            busy = false
            steps = []
            guard !SpeechGate.isNoise(ask, voicedMs: voicedMs) else {
                if !ask.isEmpty { Log.info("dropped likely-silence transcript (\(ask.count) chars, voiced \(Int(voicedMs)) ms)") }
                partial = ""
                if !shownBeforeHold && turns.isEmpty { hide() }
                return
            }
            partial = ""
            submit(ask, language: lang, voice: true)
        }
    }

    // MARK: - Turns

    func submitTyped() {
        let ask = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty, !busy else { return }
        draft = ""
        submit(ask, language: nil, voice: false)
    }

    func submit(_ ask: String, language: String?, voice: Bool) {
        if speaking { stopSpeaking() }
        follow = true
        notice = nil
        answerStarted = false
        toolRanThisTurn = false
        busy = true
        steps = []
        let t0 = Date()
        turnTask = Task {
            let ctx = await freshContext()
            context = ctx
            if !chats.indices.contains(chatIndex) { chats.append(Chat()); chatIndex = chats.count - 1 }
            let prev = chats[chatIndex].turns.last
            var turn = Turn(ask: ask, language: language, app: ctx.appName, appLabel: ctx.label, bundleID: ctx.bundleID, voice: voice)
            if let prev, prev.appLabel != ctx.label { turn.divider = "Now looking at \(ctx.label)" }
            chats[chatIndex].turns.append(turn)
            chats[chatIndex].updatedAt = Date()
            lastUsed = Date()
            addStep("Looked at \(ctx.appName.isEmpty ? "your screen" : ctx.appName)", done: true)
            if voice, let l = language, l != "en-IN", let name = Locale(identifier: "en").localizedString(forIdentifier: l) {
                addStep("Heard you in \(name.components(separatedBy: " (").first ?? name)", done: true)
            }
            let route = Router.route(ask, app: ctx.appName, computerUseAvailable: Keys.openAI != nil)
            Log.info("route \(route.rawValue)")
            if voice { startTTS(language: language) }
            do {
                if route == .computer { try await runComputer(ask: ask, ctx: ctx, language: language, voice: voice) }
                else { try await answer(ask: ask, ctx: ctx, route: route, language: language, voice: voice) }
                finishTurn(error: nil, workedFor: Date().timeIntervalSince(t0))
            } catch is CancellationError {
                finishTurn(error: nil, workedFor: Date().timeIntervalSince(t0))
            } catch {
                finishTurn(error: Self.describe(error), workedFor: Date().timeIntervalSince(t0))
            }
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? APIError { return e.errorDescription ?? "" }
        if let u = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(u.code) {
            return "Connection lost · ↵ Retry"
        }
        return error.localizedDescription
    }

    private func finishTurn(error: String?, workedFor: Double? = nil) {
        busy = false
        if chats.indices.contains(chatIndex), var t = chats[chatIndex].turns.last {
            if let error { t.error = error }
            if let workedFor, t.workedFor == nil { t.workedFor = workedFor }
            t.steps = steps.map(\.title)
            chats[chatIndex].turns[chats[chatIndex].turns.count - 1] = t
            if let error, error.contains("Retry") {
                let ask = t.ask, lang = t.language, voice = t.voice
                lastRetry = { [weak self] in
                    guard let self else { return }
                    self.chats[self.chatIndex].turns.removeLast()
                    self.submit(ask, language: lang, voice: voice)
                }
            }
        }
        if error != nil, !speaking { tts?.close(); tts = nil }
        steps = steps.map { var s = $0; if s.state == .active { s.state = .done }; return s }
        ChatStore.save(chats)
    }

    private func addStep(_ title: String, done: Bool = false) {
        steps = steps.map { var s = $0; if s.state == .active { s.state = .done }; return s }
        steps.append(StatusStep(title: title, state: done ? .done : .active))
    }

    private func appendAnswer(_ text: String, voice: Bool) {
        guard chats.indices.contains(chatIndex), !chats[chatIndex].turns.isEmpty else { return }
        if !answerStarted { answerStarted = true }
        chats[chatIndex].turns[chats[chatIndex].turns.count - 1].answer += text
        if voice { feedTTS(text) }
    }

    // MARK: - Answering

    private func historyMessages() -> [[String: Any]] {
        let previous = chats[chatIndex].turns.dropLast().suffix(6)
        var out: [[String: Any]] = []
        for t in previous where !t.answer.isEmpty {
            out.append(["role": "user", "content": t.ask])
            out.append(["role": "assistant", "content": t.rememberedAnswer])
        }
        return out
    }

    private func answer(ask: String, ctx: ScreenContext, route: Route, language: String?, voice: Bool) async throws {
        let mode = voice ? "voice" : "typed"
        let fastModel = Keys.setting("ASSISTANT_VISION_MODEL", default: "gemma4")
        let deepModel = Keys.setting("ASSISTANT_DEEP_MODEL", default: "sarvam-105b")
        let useVision = visionAvailable && ctx.screenshot != nil
        let system = Prompts.system     // identical on every turn so the prefix caches

        var userContent: Any
        var model: String
        var version: SarvamChat.Version
        var reasoning: String?
        var ctxText = ctx
        if useVision && route != .deep, let shot = ctx.screenshot, let url = ContextCapture.jpegDataURL(shot) {
            userContent = [
                ["type": "text", "text": ctx.block(language: language, outputMode: mode, includeOCR: false)],
                ["type": "image_url", "image_url": ["url": url]],
                ["type": "text", "text": "ASK: \(ask)"],
            ] as [[String: Any]]
            model = fastModel; version = .v2; reasoning = nil
        } else {
            if let shot = ctx.screenshot {
                if useVision, let url = ContextCapture.jpegDataURL(shot) {
                    addStep("Looking closely at the screen")
                    let desc = try? await SarvamChat.complete(model: fastModel, version: .v2, messages: [["role": "user", "content": [
                        ["type": "text", "text": Prompts.describeForBlindModel + ask],
                        ["type": "image_url", "image_url": ["url": url]],
                    ] as [[String: Any]]]], maxTokens: 500)
                    ctxText.ocrText = desc ?? ""
                } else {
                    addStep("Reading the screen")
                    ctxText.ocrText = await ContextCapture.ocr(shot)
                }
            }
            userContent = ctxText.block(language: language, outputMode: mode, includeOCR: true) + "\n\nASK: \(ask)"
            model = deepModel; version = .v1
            reasoning = route == .deep ? "high" : nil
        }

        var messages: [[String: Any]] = [["role": "system", "content": system]] + historyMessages()
        messages.append(["role": "user", "content": userContent])
        let tools = Tools.declarations    // every route can act; the router is only a fast path
        let maxTokens = route == .deep ? 4000 : (voice ? 900 : 1600)

        addStep(route == .deep ? "Thinking it through" : "Thinking")
        do {
            try await streamAnswer(model: model, version: version, messages: messages, tools: tools, reasoning: reasoning,
                                   maxTokens: maxTokens, voice: voice, pid: ctx.pid, language: language)
        } catch let e as APIError where version == .v2 && !answerStarted && !toolRanThisTurn && [400, 401, 403, 404, 422].contains(e.status) {
            // Vision (V2) isn't enabled for this key: fall back to on-device OCR + sarvam-105b, and remember.
            Log.error("v2 refused (\(e.status)): \(e.sanitizedMessage); falling back to OCR")
            visionAvailable = false
            try await answer(ask: ask, ctx: ctx, route: route, language: language, voice: voice)
        }
    }

    private func streamAnswer(model: String, version: SarvamChat.Version, messages: [[String: Any]], tools: [[String: Any]]?,
                              toolChoice: String = "auto", reasoning: String?, maxTokens: Int, voice: Bool, pid: pid_t, language: String?) async throws {
        var calls: [Int: (id: String, name: String, args: String)] = [:]
        let t0 = Date()
        var inThink = false
        var assistantText = ""
        for try await event in SarvamChat.stream(model: model, version: version, messages: messages, tools: tools,
                                                 toolChoice: toolChoice, reasoning: reasoning, maxTokens: maxTokens) {
            try Task.checkCancellation()
            switch event {
            case .reasoning:
                break
            case .text(var t):
                // Some models inline <think>…</think>; never show or speak it.
                if t.contains("<think>") { inThink = true; t = t.components(separatedBy: "<think>").first ?? "" }
                if inThink {
                    if let r = t.range(of: "</think>") { inThink = false; t = String(t[r.upperBound...]) } else { continue }
                }
                if !answerStarted { Log.time("first token \(model)", since: t0) }
                assistantText += t
                appendAnswer(answerStarted ? t : String(t.drop(while: { $0.isWhitespace })), voice: voice)
            case let .toolCallDelta(index, id, name, args):
                var c = calls[index] ?? (id: "", name: "", args: "")
                if let id { c.id = id }
                if let name { c.name += name }
                if let args { c.args += args }
                calls[index] = c
            case .finished:
                break
            }
        }
        if voice { flushTTS() }
        guard let first = calls.sorted(by: { $0.key < $1.key }).first?.value, !first.name.isEmpty else { return }

        // One tool call (prompts.md §5: prefer one).
        let argsObj = (try? JSONSerialization.jsonObject(with: Data(first.args.utf8)) as? [String: Any]) ?? [:]
        var call = ToolCall(id: first.id.isEmpty ? UUID().uuidString : first.id, name: first.name, arguments: argsObj, rawArguments: first.args)
        if call.name == "insert_text" {
            var a = argsObj; a["app"] = context?.appName ?? ""
            call = ToolCall(id: call.id, name: call.name, arguments: a, rawArguments: first.args)
        }
        if call.name == "use_computer" {
            // Hand off to the computer-use flow (it confirms consequential tasks itself).
            if Keys.openAI != nil {
                toolRanThisTurn = true
                if voice { startTTS(language: language) }
                try await runComputer(ask: call.string("task"), ctx: context ?? ScreenContext(), language: language, voice: voice)
                return
            }
        }
        if call.needsConfirm {
            addStep("Waiting for you to confirm")
            let ok = await askConfirm(tool: call)
            if !ok { appendAnswer(voice ? "" : "Cancelled.", voice: false); return }
        }
        addStep(call.statusText)
        toolRanThisTurn = true
        let result = call.name == "use_computer" ? "error: computer use isn't set up (no OpenAI key); tell the user which shortcut or click would do it"
            : await Tools.run(call, insertInto: pid)
        Log.info("tool \(call.name) → \(result)")
        if call.name == "insert_text", !result.hasPrefix("error") { hide(); return }

        var followUp = messages
        followUp.append(["role": "assistant", "content": assistantText,
                       "tool_calls": [["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.rawArguments]]]])
        followUp.append(["role": "tool", "tool_call_id": call.id, "content": result])
        if voice { startTTS(language: language) }
        if !assistantText.isEmpty { appendAnswer("\n\n", voice: false) }
        try await streamAnswer(model: model, version: version, messages: followUp, tools: tools, toolChoice: "none", reasoning: reasoning,
                               maxTokens: 300, voice: voice, pid: pid, language: language)
    }

    // MARK: - Confirm card

    private func askConfirm(tool: ToolCall) async -> Bool {
        pendingTool = tool
        overlay = .confirm
        if !visible { show() }
        return await withCheckedContinuation { confirmContinuation = $0 }
    }

    private func askConfirm(computer: ComputerUser.Handoff) async -> Bool {
        pendingComputer = computer
        overlay = .confirm
        if !visible { show() }
        return await withCheckedContinuation { confirmContinuation = $0 }
    }

    func resolveConfirm(_ ok: Bool) {
        guard let c = confirmContinuation else { return }
        confirmContinuation = nil
        overlay = .none
        pendingTool = nil
        pendingComputer = nil
        c.resume(returning: ok)
    }

    // MARK: - Computer use

    private func runComputer(ask: String, ctx: ScreenContext, language: String?, voice: Bool) async throws {
        addStep("Working out what to click")
        let handoff: ComputerUser.Handoff
        switch try await ComputerUser.handoff(ask: ask, context: ctx, language: language) {
        case .failure(let question): appendAnswer(question, voice: voice); if voice { flushTTS() }; return
        case .success(let h): handoff = h
        }
        if handoff.consequential {
            addStep("Waiting for you to confirm")
            guard await askConfirm(computer: handoff) else { appendAnswer(voice ? "" : "Cancelled.", voice: false); return }
        }
        addStep("Using \(ctx.appName)")
        let user = ComputerUser()
        user.monitor = hotkey
        user.onStatus = { [weak self] s in Task { @MainActor in self?.cuaStatus = s } }
        cua = user
        cuaUserTravel = 0
        cuaStatus = "Starting"
        if let app = NSRunningApplication(processIdentifier: ctx.pid) { app.activate() }
        controller?.showPill(over: ctx.windowFrame)
        try? await Task.sleep(nanoseconds: 250_000_000)
        let outcome = await user.run(task: handoff.task, pid: ctx.pid)
        cua = nil
        cuaStatus = nil
        controller?.hidePill()
        show()
        switch outcome {
        case .done(let text):
            appendAnswer(handoff.spokenTemplate.isEmpty ? text : handoff.spokenTemplate, voice: voice)
        case .stopped(let why):
            appendAnswer("Stopped: \(why).", voice: voice)
        case .failed(let why):
            throw NSError(domain: "cua", code: 1, userInfo: [NSLocalizedDescriptionKey: why])
        }
        if voice { flushTTS() }
    }

    /// Computer use stops when the user takes the mouse: a real click, or 40 pt of real movement
    /// (summed deltas, so trackpad jitter and our own synthetic moves don't count).
    private func userMouse(dx: Double, dy: Double, clicked: Bool) {
        guard let cua else { return }
        if clicked { cua.stop("you clicked"); return }
        cuaUserTravel += hypot(dx, dy)
        if cuaUserTravel > 40 { cua.stop("you moved the mouse") }
    }

    // MARK: - Voice out (Bulbul)

    private func startTTS(language: String?) {
        tts?.close()
        player.stop()
        let t = SarvamTTS(language: Sarvam.ttsLanguage(for: language), sampleRate: 22050)
        t.onAudio = { [weak self] pcm in self?.player.enqueue(int16: pcm) }
        t.onFinal = { [weak self] in self?.ttsFinalReceived = true; self?.playbackDrained() }
        t.onError = { [weak self] m in Log.error("tts: \(m)"); self?.speakingEnded() }
        do { try t.connect() } catch { Log.error("tts connect: \(error.localizedDescription)"); return }
        tts = t
        ttsFinalReceived = false
        sentenceBuffer = ""
        spokenChars = 0
    }

    private func feedTTS(_ text: String) {
        guard tts != nil else { return }
        sentenceBuffer += text
        // Send each complete sentence as soon as it exists (prompts.md §8).
        while let r = sentenceBuffer.range(of: #"[.?!।॥\n]+(\s|$)"#, options: .regularExpression), r.upperBound < sentenceBuffer.endIndex || sentenceBuffer.hasSuffix("\n") {
            let sentence = String(sentenceBuffer[..<r.upperBound])
            sentenceBuffer = String(sentenceBuffer[r.upperBound...])
            speakSentence(sentence)
        }
    }

    private func flushTTS() {
        guard let tts else { return }
        if !sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { speakSentence(sentenceBuffer) }
        sentenceBuffer = ""
        tts.flush()
    }

    private func speakSentence(_ raw: String) {
        spokenChars += raw.count
        let clean = Self.cleanForSpeech(raw)
        guard !clean.isEmpty else { return }
        if !speaking { speaking = true }
        tts?.speak(clean)
    }

    nonisolated static func cleanForSpeech(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "the link", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_#>\[\]|]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func playbackDrained() {
        guard speaking else { return }
        if ttsFinalReceived && player.playedSeconds >= player.scheduledSeconds - 0.01 { speakingEnded() }
    }

    private func speakingEnded() {
        speaking = false
        tts?.close()
        tts = nil
    }

    /// Barge-in: clear playback instantly, close the socket (there is no cancel message),
    /// and remember only what was heard.
    func stopSpeaking() {
        guard speaking || tts != nil else { return }
        let played = player.playedSeconds, scheduled = max(player.scheduledSeconds, 0.001)
        player.stop()
        tts?.close()
        tts = nil
        speaking = false
        if chats.indices.contains(chatIndex), !chats[chatIndex].turns.isEmpty {
            let i = chats[chatIndex].turns.count - 1
            let heard = Int(Double(spokenChars) * min(1, played / scheduled))
            chats[chatIndex].turns[i].spokenUpTo = heard
            ChatStore.save(chats)
        }
    }

    func readAloudAgain() {
        guard let t = turns.last, !t.answer.isEmpty else { return }
        startTTS(language: t.language)
        feedTTS(t.answer + "\n")
        flushTTS()
    }

    // MARK: - Chats

    func previousChat() { guard chatIndex > 0 else { return }; pruneEmpty(); chatIndex = max(0, chatIndex - 1); afterSwitch() }
    func nextChat() { guard chatIndex < chats.count - 1 else { return }; chatIndex += 1; afterSwitch() }
    func newChat() {
        cancelAll()
        pruneEmpty()
        chats.append(Chat())
        chatIndex = chats.count - 1
        afterSwitch()
    }
    func openChat(_ id: UUID) { if let i = chats.firstIndex(where: { $0.id == id }) { chatIndex = i }; overlay = .none; afterSwitch() }

    private func pruneEmpty() {
        let current = chat.id
        chats.removeAll { $0.turns.isEmpty && $0.id != current }
        chatIndex = chats.firstIndex { $0.id == current } ?? max(0, chats.count - 1)
    }

    private func afterSwitch() {
        if speaking { stopSpeaking() }
        lastUsed = Date()
        follow = true
        overlay = .none
    }

    // MARK: - Overlays

    var recentChats: [Chat] {
        let all = chats.filter { !$0.turns.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }
        guard !filter.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }

    var switchableApps: [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        let current = context?.pid
        var apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        if !filter.isEmpty { apps = apps.filter { ($0.localizedName ?? "").localizedCaseInsensitiveContains(filter) } }
        let others = apps.filter { $0.processIdentifier != current }
        let cur = apps.filter { $0.processIdentifier == current }
        return Array(others.prefix(6)) + cur
    }

    func switchTo(_ app: NSRunningApplication) {
        let t0 = Date()
        overlay = .none
        FocusMove.begin()
        app.activate()
        Task {
            for _ in 0..<20 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            captureContext()
            let c = await contextTask!.value
            context = c
            controller?.makeKey()
            notice = String(format: "Brought %@ forward · captured the window %.2fs", c.appName, Date().timeIntervalSince(t0))
        }
    }

    func actions() -> [ActionItem] {
        var items: [ActionItem] = []
        if let last = turns.last, !last.answer.isEmpty {
            items.append(ActionItem(section: "Answer", title: "Copy Answer", icon: "copy", keys: ["⌘", "C"]) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(last.answer, forType: .string)
                self.overlay = .none
            })
            items.append(ActionItem(section: "Answer", title: "Insert Answer", icon: "enter", keys: ["⌘", "↵"]) { self.insertLastAnswer() })
            items.append(ActionItem(section: "Answer", title: "Read Aloud Again", icon: "speaker", keys: []) { self.overlay = .none; self.readAloudAgain() })
            items.append(ActionItem(section: "Answer", title: "Think Harder", icon: "loading", keys: []) { self.overlay = .none; self.thinkHarder() })
        }
        items.append(ActionItem(title: "New Chat", icon: "plus", keys: ["⌘", "N"]) { self.newChat() })
        items.append(ActionItem(title: "Chats", icon: "chats", keys: []) { self.filter = ""; self.selection = 0; self.overlay = .chats })
        items.append(ActionItem(title: "Previous Chat", icon: "left", keys: ["⌘", "["]) { self.previousChat() })
        items.append(ActionItem(title: "Next Chat", icon: "right", keys: ["⌘", "]"]) { self.nextChat() })
        items.append(ActionItem(section: "Screen", title: "Look at Another App", icon: "search", keys: []) { self.filter = ""; self.selection = 0; self.overlay = .apps })
        return items
    }

    /// The ⌘K popover's rows after its search field.
    func filteredActions() -> [ActionItem] {
        let all = actions()
        guard overlay == .actions, !filter.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(filter) || $0.section.localizedCaseInsensitiveContains(filter) }
    }

    func insertLastAnswer() {
        guard let t = turns.last, !t.answer.isEmpty else { return }
        let pid = context?.pid
        hide()
        Task { await Inserter.insert(t.answer, into: pid) }
    }

    func thinkHarder() {
        guard let t = turns.last, !busy else { return }
        submit("Think harder and answer again, carefully: \(t.ask)", language: t.language, voice: t.voice)
    }

    func retry() { lastRetry?(); lastRetry = nil }

    // MARK: - Keys (panel is key)

    /// Returns true when the key was handled and should be swallowed.
    func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 53: // Esc: the event tap already handled it if the tap is running (even listen-only), so never twice
            return hotkey.isRunning ? true : escape()
        case 36, 76: // Return
            if e.modifierFlags.contains(.shift) { return false }
            switch overlay {
            case .confirm: resolveConfirm(true); return true
            case .actions: let a = filteredActions(); if a.indices.contains(selection) { a[selection].perform() }; return true
            case .chats: let c = recentChats; if c.indices.contains(selection) { openChat(c[selection].id) }; return true
            case .apps: let a = switchableApps; if a.indices.contains(selection) { switchTo(a[selection]) }; return true
            case .none:
                if cmd { insertLastAnswer(); return true }
                if !draft.trimmingCharacters(in: .whitespaces).isEmpty { submitTyped(); return true }
                if notice?.contains("Retry") == true || turns.last?.error?.contains("Retry") == true { retry(); return true }
                if lastAnswerTyped && !busy { insertLastAnswer(); return true }
                return false
            }
        case 126: if overlay != .none && overlay != .confirm { selection = max(0, selection - 1); return true }
        case 125: if overlay != .none && overlay != .confirm { selection += 1; clampSelection(); return true }
        case 33 where cmd: previousChat(); return true     // ⌘[
        case 30 where cmd: nextChat(); return true         // ⌘]
        case 45 where cmd: newChat(); return true          // ⌘N
        case 40 where cmd:                                 // ⌘K
            overlay = overlay == .actions ? .none : .actions
            selection = 0
            filter = ""
            return true
        default: break
        }
        // Typing while listening switches to typed mode and stops the mic.
        if listening, !cmd, let chars = e.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            let text = partial
            discardPreroll()
            hotkey.resetGesture()
            input = .typed
            draft = (text.isEmpty ? "" : text + " ") + chars
            focusField = true
            return true
        }
        // Filter overlay lists by typing.
        if overlay == .chats || overlay == .apps || overlay == .actions, !cmd, let chars = e.characters {
            if e.keyCode == 51 { if !filter.isEmpty { filter.removeLast() }; return true }
            if chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.whitespaces).union(.punctuationCharacters).contains($0) }) {
                filter += chars; selection = 0; return true
            }
        }
        return false
    }

    private func clampSelection() {
        let n: Int
        switch overlay {
        case .actions: n = filteredActions().count
        case .chats: n = recentChats.count
        case .apps: n = switchableApps.count
        default: n = 0
        }
        selection = min(selection, max(0, n - 1))
    }
}
