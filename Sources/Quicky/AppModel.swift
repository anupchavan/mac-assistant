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
    private let extensionPicker = ExtensionPicker()
    /// Extensions whose tools this turn's model sees (picked while the user spoke).
    private var turnExtensions: Set<String> = []
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
    private var stt: SpeechToText?
    private var contextTask: Task<ScreenContext, Never>?
    private var contextAt = Date.distantPast
    private var turnTask: Task<Void, Never>?
    private var tts: TextToSpeech?
    private var player = PCMPlayer(sampleRate: Double(TTS.sampleRate))
    private var tags = AudioTags(speakTags: false)   // this turn's answer stream: tags spoken, never shown
    private var ttsFinalReceived = false
    private var sentenceBuffer = ""
    private var spokenChars = 0          // answer characters handed to TTS
    private var shownBeforeHold = false
    private var confirmContinuation: CheckedContinuation<Bool, Never>?
    private var cua: ComputerUser?
    private var cuaUserTravel: Double = 0     // points the user has moved the mouse during computer use
    private var gate = SpeechGate()
    private var speechFilter: SpeechFilter?
    private var tapStoppedSpeech = false
    private var lastRetry: (() -> Void)?
    private var toolRanThisTurn = false     // never re-run a turn whose tool already acted
    private var owesWords = false           // a lookup's result went back to the model, so the turn must end in words
    private var searchPrefetch: Task<String, Never>?   // speculative web search for the ask, started with the model call
    private var warmTTS: (socket: TextToSpeech, provider: TTS.Provider, at: Date)?   // opened while the user finishes speaking, adopted by startTTS
    private var lastLanguage: String?
    private var turnStart = Date()
    private var firstAudioLogged = true
    private var lastWarm = Date.distantPast
    private var actionFailedThisTurn = false   // a tool erred or changed nothing; never end such a turn in silence
    private var repairsThisTurn = 0            // model retries after its tool arguments failed ToolSchema
    static let maxRepairs = 2
    private var visionAvailable = true          // until this key's V2 refuses a screenshot, for this launch

    init() {
        let loaded = ChatStore.load()
        let initial = loaded.isEmpty ? [Chat()] : loaded
        chats = initial
        chatIndex = initial.count - 1
        if let last = initial.last?.updatedAt { lastUsed = last }
        player.onDrained = { [weak self] in self?.playbackDrained() }
        hotkey.onGesture = { [weak self] g in self?.gesture(g) }
        // A `run` program that reaches a write/external tool pauses on the same confirm card as a direct call.
        Composer.confirm.value = { [weak self] call in await self?.confirmFromProgram(call) ?? false }
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
            // ⇧ + trigger / trigger + Space toggles: opens typing, or closes the panel if it was already open.
            let wasOpen = listening ? shownBeforeHold : visible
            discardPreroll()
            if wasOpen { hotkey.resetGesture(); hide() } else { showTyped() }
        case .tap:
            if listening && handsFree { endListening() }
            else if !listening {
                discardPreroll()
                // A plain trigger tap on an open, idle panel closes it (a tap that stopped speech only stops speech).
                if visible && !tapStoppedSpeech && !busy && overlay != .confirm && cua == nil { hide() }
            }
        case .newChat:
            discardPreroll()
            newChat()
            showTyped()
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
        steps = []
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
        warmConnection()
        let s = STT.make()
        s.onPartial = { [weak self] text in
            self?.partial = text
            self?.extensionPicker.hear(text, app: NSWorkspace.shared.frontmostApplication?.localizedName ?? "")
        }
        s.onError = { [weak self] m in self?.notice = m }
        s.connect()
        stt = s
        partial = ""
        gate = SpeechGate()
        let filter = SpeechFilter { [weak s] in s?.send($0) }
        speechFilter = filter
        mic.onChunk = { [weak self] chunk, level in
            filter.pass(chunk)
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
        speechFilter = nil
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
        // Nothing was said: no STT call, no turn. The classifier decides; loudness can't tell typing from talking.
        let spoke = speechFilter?.finish() ?? gate.heardSpeech
        speechFilter = nil
        if duration < 0.3 || !spoke {
            Log.info(String(format: "no speech (voiced %.0f ms, floor %.3f); discarded", gate.voicedMs, gate.noiseFloor))
            s.close(); partial = ""
            if !shownBeforeHold && turns.isEmpty { hide() }
            return
        }
        prewarmTTS()
        busy = true
        steps = [StatusStep(title: "Listening", state: .active)]
        let t0 = Date()
        Task {
            let (text, lang) = await s.finish(timeout: 3)
            Log.time("stt.final", since: t0)
            let ask = text.trimmingCharacters(in: .whitespacesAndNewlines)
            busy = false
            steps = []
            guard !SpeechGate.isNoise(ask) else {
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
        owesWords = false
        actionFailedThisTurn = false
        repairsThisTurn = 0
        busy = true
        steps = []
        let t0 = Date()
        turnStart = t0
        firstAudioLogged = !voice
        if voice { lastLanguage = language }
        turnTask = Task {
            var ctx = await freshContext()
            context = ctx
            if !chats.indices.contains(chatIndex) { chats.append(Chat()); chatIndex = chats.count - 1 }
            let prev = chats[chatIndex].turns.last
            var turn = Turn(ask: ask, language: language, app: ctx.appName, appLabel: ctx.label, bundleID: ctx.bundleID, voice: voice)
            if let prev, prev.appLabel != ctx.label { turn.divider = "Now looking at \(ctx.label)" }
            if !ctx.finderSelection.isEmpty { turn.contextNote = "FINDER_SELECTION then:\n" + ctx.finderSelection.prefix(20).joined(separator: "\n") }
            else if !ctx.browserURL.isEmpty { turn.contextNote = "BROWSER then: \(ctx.browserURL)" }
            chats[chatIndex].turns.append(turn)
            chats[chatIndex].updatedAt = Date()
            lastUsed = Date()
            addStep("Looked at \(ctx.appName.isEmpty ? "your screen" : ctx.appName)", done: true)
            if voice, let l = language, l != "en-IN", let name = Locale(identifier: "en").localizedString(forIdentifier: l) {
                addStep("Heard you in \(name.components(separatedBy: " (").first ?? name)", done: true)
            }
            if voice { startTTS(language: language) }
            Log.info("ask: \(ask.prefix(200))")
            if await runReflex(ask: ask, ctx: ctx, voice: voice) {
                Log.time("turn reflex total", since: t0)
                finishTurn(error: nil, workedFor: Date().timeIntervalSince(t0))
                return
            }
            turnExtensions = await extensionPicker.pick(final: ask, app: ctx.appName, url: ctx.browserURL, wait: voice ? 0.15 : 0.4)
            // Selection the app won't expose: copy it, but only for asks about the screen, and after the
            // reflexes so "close this tab" never waits on it. Finder's ⌘C copies files; its selection is read separately.
            if ctx.selectionUnreadable, ctx.pid != 0, ctx.bundleID != "com.apple.finder", Router.looksAtScreen(ask),
               let s = await Selection.viaClipboard(pid: ctx.pid) {
                ctx.selection = s
                context = ctx
            }
            var route = Router.route(ask, app: ctx.appName, computerUseAvailable: Keys.openAI != nil)
            // With the window's controls in hand, the model can press the button itself in milliseconds;
            // computer use (seconds per step) is only for what it can't reach.
            if route == .computer, !ctx.controls.isEmpty { route = .agent }
            Log.info("route \(route.rawValue)")
            do {
                if route == .computer { try await runComputer(ask: ask, ctx: ctx, language: language, voice: voice) }
                else { try await answer(ask: ask, ctx: ctx, route: route, language: language, voice: voice) }
                if actionFailedThisTurn, chats[chatIndex].turns.last?.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false {
                    if voice && (tts == nil || ttsFinalReceived) { startTTS(language: language) }
                    appendAnswer("That didn't work.", voice: voice)
                    if voice { flushTTS() }
                }
                Log.time("turn total", since: t0)
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

    /// Facts about what this turn did, kept with the turn so later turns' history carries them.
    private func noteOnTurn(_ note: String) {
        guard chats.indices.contains(chatIndex), !chats[chatIndex].turns.isEmpty else { return }
        let i = chats[chatIndex].turns.count - 1
        chats[chatIndex].turns[i].contextNote = [chats[chatIndex].turns[i].contextNote, note].compactMap { $0 }.joined(separator: "\n")
    }

    private func addStep(_ title: String, done: Bool = false) {
        steps = steps.map { var s = $0; if s.state == .active { s.state = .done }; return s }
        steps.append(StatusStep(title: title, state: done ? .done : .active))
    }

    private func appendAnswer(_ text: String, voice: Bool) {
        guard chats.indices.contains(chatIndex), !chats[chatIndex].turns.isEmpty else { return }
        if !answerStarted { answerStarted = true }
        guard voice else { chats[chatIndex].turns[chats[chatIndex].turns.count - 1].answer += text; return }
        let (shown, spoken) = tags.feed(text)
        chats[chatIndex].turns[chats[chatIndex].turns.count - 1].answer += shown
        feedTTS(spoken)
    }

    // MARK: - Answering

    nonisolated static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 90 { return "\(max(s, 1)) s ago" }
        if s < 5400 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }

    private func historyMessages() -> [[String: Any]] {
        let previous = chats[chatIndex].turns.dropLast().suffix(6)
        var out: [[String: Any]] = []
        for t in previous {
            // A silent turn is replayed only if it did something, and then as what it did. A made-up line
            // like "(did it, said nothing)" gets copied back word for word as a reply.
            let did = (t.contextNote ?? "").split(separator: "\n").filter { $0.hasPrefix("Quicky did: ") }
                .map { String($0.dropFirst("Quicky did: ".count)) }.joined(separator: "; ")
            let reply = t.answer.isEmpty ? did : t.rememberedAnswer
            if reply.isEmpty { continue }
            // When and where each earlier ask happened, so "search for X" four seconds after "open YouTube"
            // reads as a follow-up on that screen, not a fresh question.
            let when = "[\(Self.ago(t.at)) in \(t.appLabel.isEmpty ? "another app" : t.appLabel)]"
            out.append(["role": "user", "content": "\(when) \(t.ask)" + (t.contextNote.map { "\n\n(\($0))" } ?? "")])
            out.append(["role": "assistant", "content": reply])
        }
        return out
    }

    private func answer(ask: String, ctx: ScreenContext, route: Route, language: String?, voice: Bool) async throws {
        // Eleven v4 can act out audio tags; only then does the model hear it may use them.
        let expressive = voice && TTS.provider.isElevenLabs
        tags = AudioTags(speakTags: expressive)
        let mode = expressive ? "voice+tags" : voice ? "voice" : "typed"
        let fastModel = Keys.setting("ASSISTANT_VISION_MODEL", default: "gemma4")
        // A key added to ~/.zshrc after launch: look again before giving up on the picked model.
        let picked = Gemini.pickedModel
        if Gemini.isOptional(picked) && !Gemini.ready(picked) {
            Keys.reload()
            if !Gemini.ready(picked) {
                let label = Gemini.choices.first { $0.id == picked }?.label ?? picked
                Log.error("\(picked) has no key; answering with \(Gemini.answerModel)")
                addStep("\(label) has no key, Sarvam answered", done: true)
            }
        }
        let deepModel = route == .agent && !ctx.controls.isEmpty ? Gemini.actionModel : Gemini.answerModel
        // Only asks that point at the screen go to the vision model with the screenshot. A general question
        // ("when is Sarvam's 1T model launching?") goes to the main model, which answers from what it knows.
        let screenAsk = Router.looksAtScreen(ask)
        Log.info("screen ask: \(screenAsk)")
        let useVision = visionAvailable && ctx.screenshot != nil && screenAsk
        searchPrefetch?.cancel(); searchPrefetch = nil
        if WebSearch.available, ExtensionHost.isEnabled("web"), Router.wantsFresh(ask) {
            searchPrefetch = Task.detached { await WebSearch.run(query: ask) }
        }
        let system = Prompts.system     // identical on every turn so the prefix caches

        var userContent: Any
        var model: String
        var version: SarvamChat.Version
        var reasoning: String?
        var ctxText = ctx
        if useVision && route != .deep, let shot = ctx.screenshot, let url = ContextCapture.jpegDataURL(shot) {
            userContent = [
                ["type": "text", "text": ctx.block(language: language, outputMode: mode, includeOCR: false, includeLinks: route == .agent)],
                ["type": "image_url", "image_url": ["url": url]],
                ["type": "text", "text": "ASK: \(ask)"],
            ] as [[String: Any]]
            // Gemini and Claude see images themselves, so when they answer they take screenshot asks too.
            model = Gemini.seesImages(deepModel) ? deepModel : fastModel; version = .v2; reasoning = nil
        } else {
            if let shot = ctx.screenshot, screenAsk {
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
            userContent = ctxText.block(language: language, outputMode: mode, includeOCR: true, includeLinks: route == .agent) + "\n\nASK: \(ask)"
            model = deepModel; version = .v1
            reasoning = route == .deep ? "high" : nil
        }

        var messages: [[String: Any]] = [["role": "system", "content": system]] + historyMessages()
        messages.append(["role": "user", "content": userContent])
        // Every route can act; the router is only a fast path. Extensions join only when picked for this ask.
        let tools = Tools.builtIn + ExtensionHost.declarations(for: turnExtensions)
        let maxTokens = route == .deep ? 4000 : (voice ? 900 : 1600)

        addStep(route == .deep ? "Thinking it through" : "Thinking")
        do {
            try await streamAnswer(model: model, version: version, messages: messages, tools: tools, reasoning: reasoning,
                                   maxTokens: maxTokens, voice: voice, pid: ctx.pid, language: language)
            if !answerStarted && (!toolRanThisTurn || owesWords) {
                // Nothing said and nothing done, or a lookup nobody put into words: say so instead of ending on a blank panel.
                Log.error(owesWords ? "turn ended with a tool result but no answer" : "turn ended with no answer and no action")
                addStep("The model returned nothing")
                if let i = steps.indices.last { steps[i].state = .error }
            }
        } catch let e as APIError where version == .v2 && !answerStarted && !toolRanThisTurn && [400, 401, 403, 404, 422].contains(e.status) {
            // Vision (V2) isn't enabled for this key: fall back to on-device OCR + sarvam-105b until relaunch.
            Log.error("v2 refused (\(e.status)): \(e.sanitizedMessage); falling back to OCR")
            visionAvailable = false
            try await answer(ask: ask, ctx: ctx, route: route, language: language, voice: voice)
        }
    }

    private func streamAnswer(model: String, version: SarvamChat.Version, messages: [[String: Any]], tools: [[String: Any]]?,
                              toolChoice: String = "auto", reasoning: String?, maxTokens: Int, voice: Bool, pid: pid_t, language: String?,
                              hop: Int = 0) async throws {
        var calls: [Int: (id: String, name: String, args: String)] = [:]
        // Safe, instant tools start the moment their arguments are complete JSON, while the model is still
        // streaming (the next call, or just the closing events). A JSON object can't be a prefix of a longer
        // one, so a successful parse means the arguments are final.
        var early: [Int: Task<String, Never>] = [:]
        let prefetched = searchPrefetch
        let t0 = Date()
        var inThink = false
        var assistantText = ""
        var answeredBy = model      // the model that actually replied (differs after a fallback)
        func startEarly(_ i: Int) {
            guard early[i] == nil, let c = calls[i], !c.name.isEmpty, c.args.hasSuffix("}"),
                  let a = try? JSONSerialization.jsonObject(with: Data(c.args.utf8)) as? [String: Any] else { return }
            let lead = calls[0]?.name ?? ""
            let call = ToolCall(id: c.id, name: c.name, arguments: a, rawArguments: c.args)
            // Same rules as below: the first call, plus more of the same kind for search and links.
            guard i == 0 || (c.name == lead && ["web_search", "open_url"].contains(c.name)), Self.runsEarly(call) else { return }
            guard ToolSchema.problem(call, tools: tools ?? []) == nil else { return }
            if c.name == "web_search", i == 0, prefetched != nil { return }
            if c.name == "open_url", early.count >= 5 { return }
            if c.name == "press", notSetReply(call) != nil { return }
            if c.name != "web_search" { toolRanThisTurn = true }
            Log.time("tool \(c.name)#\(i) args complete, starting", since: t0)
            early[i] = Task.detached { await Tools.run(call, insertInto: pid) }
        }
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
                if !answerStarted { Log.time("first token \(answeredBy)", since: t0) }
                assistantText += t
                appendAnswer(answerStarted ? t : String(t.drop(while: { $0.isWhitespace })), voice: voice)
            case let .toolCallDelta(index, id, name, args):
                var c = calls[index] ?? (id: "", name: "", args: "")
                if let id { c.id = id }
                if let name { c.name += name }
                if let args { c.args += args }
                calls[index] = c
                startEarly(index)
            case .finished:
                break
            case let .fellBack(to, reason):
                answeredBy = to
                let picked = Gemini.choices.first { $0.id == model }?.label ?? model
                let title = "\(picked) failed (\(reason)), \(Gemini.choices.first { $0.id == to }?.label ?? to) answered"
                if !steps.contains(where: { $0.title == title }) { addStep(title, done: true) }
            }
        }
        let ordered = calls.sorted(by: { $0.key < $1.key })
        if hop > 0, assistantText.isEmpty, ordered.isEmpty { Log.error("follow-up from \(answeredBy) returned no text and no tool call") }
        if voice {
            if ordered.isEmpty {
                flushTTS()
            } else {
                // Keep the TTS stream open across the tool, so a lead-in and the reply play as one utterance
                // on a socket that is already connected.
                if !sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { speakSentence(sentenceBuffer) }
                sentenceBuffer = ""
            }
        }
        guard let first = ordered.first?.value, !first.name.isEmpty else { return }
        Log.time("tool call \(first.name) \(first.args.prefix(160)) from \(answeredBy)\(hop > 0 ? " (step \(hop + 1))" : "")", since: t0)
        func toolCall(_ i: Int, _ c: (id: String, name: String, args: String)) -> ToolCall {
            let a = (try? JSONSerialization.jsonObject(with: Data(c.args.utf8)) as? [String: Any]) ?? [:]
            return ToolCall(id: c.id.isEmpty ? "call_\(i)" : c.id, name: c.name, arguments: a, rawArguments: c.args)
        }
        if first.name == "press", let c = Controls.latest.value[Controls.id(toolCall(0, first))] { Log.info("press target: \(c.line)") }
        for c in ordered.map(\.value) { if let id = Extensions.owner(of: c.name) { extensionPicker.used(id) } }
        func followUp(_ ran: [ToolCall], _ results: [String], maxTokens: Int, choice: String = "none") async throws {
            var f = messages
            f.append(["role": "assistant", "content": assistantText,
                      "tool_calls": ran.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.rawArguments]] }])
            for (c, r) in zip(ran, results) { f.append(["role": "tool", "tool_call_id": c.id, "content": r]) }
            if voice && (tts == nil || ttsFinalReceived) { startTTS(language: language) }
            if !assistantText.isEmpty { appendAnswer("\n\n", voice: false) }
            owesWords = true
            Log.info("follow-up to \(model) with \(ran.map(\.name).joined(separator: ", ")) (\(results.map(\.count).reduce(0, +)) chars)")
            try await streamAnswer(model: model, version: version, messages: f, tools: tools, toolChoice: choice, reasoning: reasoning,
                                   maxTokens: maxTokens, voice: voice, pid: pid, language: language, hop: hop + 1)
        }

        // Arguments that don't fit the declared schema never run. The model gets the exact problem back and
        // may fix it (maxRepairs per turn); after that the turn says plainly that nothing happened.
        let problems = ordered.map { ToolSchema.problem(toolCall($0.key, $0.value), tools: tools ?? []) }
        if problems.contains(where: { $0 != nil }) {
            let sent = ordered.map { toolCall($0.key, $0.value) }
            var results: [String] = []
            for (n, p) in problems.enumerated() {
                if let p { results.append(p); continue }
                if let started = early[ordered[n].key] { results.append(await started.value); continue }
                results.append("error: not run, because another call in this reply had bad arguments; send it again with the fixed one")
            }
            for p in problems.compactMap({ $0 }) { Log.info("tool args rejected (try \(repairsThisTurn + 1) of \(Self.maxRepairs + 1)): \(p)") }
            if repairsThisTurn < Self.maxRepairs {
                repairsThisTurn += 1
                try await followUp(sent, results, maxTokens: 300, choice: "auto")
            } else {
                actionFailedThisTurn = true
                addStep("Couldn't work out the request")
                if let i = steps.indices.last { steps[i].state = .error }
                let gaveUp = results.map { $0.hasPrefix("error") ? $0 + " (gave up after \(Self.maxRepairs + 1) tries; nothing was done)" : $0 }
                try await followUp(sent, gaveUp, maxTokens: 120)
            }
            return
        }

        if first.name == "web_search" {
            // Read-only, so no confirm: every search the model asked for runs at once, then the model answers from them.
            let searches = ordered.filter { $0.value.name == "web_search" }.map { toolCall($0.key, $0.value) }
            let indices = ordered.filter { $0.value.name == "web_search" }.map(\.key)
            addStep(searches.count == 1 ? searches[0].statusText : "Searching the web (\(searches.count) searches)")
            searchPrefetch = nil
            let ts = Date()
            let results: [String] = await withTaskGroup(of: (Int, String).self) { group in
                for (i, s) in searches.enumerated() {
                    let started = early[indices[i]]
                    group.addTask {
                        if let started { return (i, await started.value) }
                        if i == 0, let p = prefetched { return (i, await p.value) }
                        return (i, await WebSearch.run(query: s.string("query")))
                    }
                }
                var out = Array(repeating: "", count: searches.count)
                for await (i, r) in group { out[i] = r }
                return out
            }
            Log.time("web_search ×\(searches.count)\(prefetched == nil ? "" : " (prefetched)") wait", since: ts)
            // "auto", so a search can lead to an action ("open five Instagram profiles" finds them, then opens them).
            // Capped by hop so it can't keep searching.
            try await followUp(searches, results, maxTokens: voice ? 400 : 1000, choice: hop < 2 ? "auto" : "none")
            return
        }

        // Links, apps, shortcuts, clipboard: the first call, plus more open_url calls ("their socials").
        var batch = [toolCall(ordered[0].key, first)]
        var batchIdx = [ordered[0].key]
        if first.name == "open_url" {
            for (i, c) in ordered.dropFirst() where c.name == "open_url" && batch.count < 5 { batch.append(toolCall(i, c)); batchIdx.append(i) }
        }
        var call = batch[0]
        if call.name == "insert_text" {
            var a = call.arguments; a["app"] = context?.appName ?? ""
            call = ToolCall(id: call.id, name: call.name, arguments: a, rawArguments: call.rawArguments)
            batch[0] = call
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
        var confirmed = false
        if let line = notSetReply(call) {
            Log.info("refused model press: \(line)")
            if voice && (tts == nil || ttsFinalReceived) { startTTS(language: language) }
            appendAnswer(line, voice: voice)
            if voice { flushTTS() }
            return
        }
        // The model may only press a consequential control (Block, Delete, Send) the ask actually names;
        // it once reached for Block while trying to unfollow. No card, no press: it hears why instead.
        if call.name == "press", call.needsConfirm, let c = Controls.latest.value[Controls.id(call)],
           let ask = chats.indices.contains(chatIndex) ? chats[chatIndex].turns.last?.ask : nil, !Reflex.related(ask, c.label) {
            Log.info("refused model press of “\(c.label)”: not what was asked")
            actionFailedThisTurn = true
            try await followUp([call], ["error: not pressed. “\(c.label)” is not what the user asked for, and it can't be undone. Say in one short sentence that you couldn't find how to do what they asked here."], maxTokens: 120)
            return
        }
        if call.needsConfirm {
            if voice { flushTTS() }
            addStep("Waiting for you to confirm")
            let ok = await askConfirm(tool: call)
            if !ok { appendAnswer(voice ? "" : "Cancelled.", voice: false); return }
            confirmed = true
        }
        addStep(batch.count == 1 ? call.statusText : "Opening \(batch.count) links")
        toolRanThisTurn = true
        let tr = Date()
        let results: [String]
        if call.name == "use_computer" {
            results = ["error: computer use isn't set up (no OpenAI key); tell the user which shortcut or click would do it"]
        } else {
            results = await withTaskGroup(of: (Int, String).self) { group in
                for (n, c) in batch.enumerated() {
                    let started = early[batchIdx[n]]
                    group.addTask {
                        if let started { return (n, await started.value) }
                        return (n, await Tools.run(c, insertInto: pid))
                    }
                }
                var out = Array(repeating: "", count: batch.count)
                for await (n, r) in group { out[n] = r }
                return out
            }
        }
        Log.time("tool \(call.name) ×\(batch.count) ran → \(results.joined(separator: ", ").prefix(120))", since: tr)
        if call.name == "insert_text", !results[0].hasPrefix("error") { hide(); return }
        actionFailedThisTurn = results.contains { $0.hasPrefix("error") || $0.hasSuffix(Controls.unchangedMarker) }
        // A failed tool shows as failed in the steps, not as a tick.
        if results.contains(where: { $0.hasPrefix("error") }), let i = steps.indices.last { steps[i].state = .error }
        // So a later "close them", "undo that" or "open it again" can see what this turn actually did.
        if call.name == "open_url" {
            noteOnTurn("Quicky did: opened tabs " + batch.flatMap(\.urlList).joined(separator: " "))
        } else if !results[0].hasPrefix("error") {
            noteOnTurn("Quicky did: \(call.name) \(call.rawArguments.prefix(200)) → \(results[0].prefix(120))")
        }

        // The press opened a menu or dialog (Following → Unfollow): one more model step with what opened,
        // tools allowed, so it can press the item the ask was really about. At most three steps.
        if call.name == "press", Controls.needsNextStep(results[0]), hop < 3 {
            Log.time("press not done yet (\(results[0].contains(Controls.openedMarker) ? "opened" : results[0].contains(Controls.closedMarker) ? "closed" : "no change")); step \(hop + 2)", since: t0)
            try await followUp(batch, results, maxTokens: 300, choice: "auto")
            return
        }

        // Success on a plain action needs no second model trip and no words: the screen already shows it.
        if let reply = Self.localReply(batch, results: results, saidAlready: !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                       language: language) {
            Log.time("tool \(call.name) done, local reply (no follow-up model call)", since: t0)
            if !reply.isEmpty {
                if voice && (tts == nil || ttsFinalReceived || confirmed) { startTTS(language: language) }
                if !assistantText.isEmpty { appendAnswer(" ", voice: false) }
                appendAnswer(reply, voice: voice)
            }
            if voice { flushTTS() }
            return
        }
        try await followUp(batch, results, maxTokens: 300)
    }

    /// "Unfollow" while the page shows Follow: the line to say instead of pressing.
    private func notSetReply(_ call: ToolCall) -> String? {
        guard call.name == "press", let c = Controls.latest.value[Controls.id(call)],
              let ask = chats.indices.contains(chatIndex) ? chats[chatIndex].turns.last?.ask : nil else { return nil }
        return Controls.notSetReply(ask: ask, label: c.label)
    }

    /// Tools that may start before the model finishes: no confirm, nothing to undo, nothing that needs the panel.
    nonisolated static func runsEarly(_ call: ToolCall) -> Bool {
        guard !call.needsConfirm else { return false }
        return ["web_search", "open_url", "open_app", "press_shortcut", "press", "type_text", "copy_to_clipboard", "reveal_or_open_file"].contains(call.name)
            || Extensions.readOnly(call.name)
    }

    /// What to say after a tool that worked, or nil to let the model explain (errors, a press that changed
    /// nothing, tools whose result needs words). "" means say nothing: the change is right there on screen,
    /// and "Pressed Follow" would only read the UI back. Data the user can't see (a file moved, an event
    /// added) gets one short line.
    nonisolated static func localReply(_ calls: [ToolCall], results: [String], saidAlready: Bool, language: String?) -> String? {
        guard let first = calls.first, !results.contains(where: { $0.hasPrefix("error") || Controls.needsNextStep($0) }) else { return nil }
        // A program's own sentence, its question for the user, or an extension result that says what to say.
        if first.name == "run" || ExtensionHost.tool(first.name) != nil { return Composer.spoken(results[0]) }
        if ["open_url", "open_app", "press_shortcut", "press", "type_text", "reveal_or_open_file"].contains(first.name) {
            return ""
        }
        if let l = language, !l.hasPrefix("en") { return l == "hi-IN" && !saidAlready ? "Ho gaya." : (saidAlready ? "" : nil) }
        if saidAlready { return "" }
        switch first.name {
        case "copy_to_clipboard": return "Copied."
        case "create_event": return "Added to your calendar."
        case "create_reminder": return "Reminder set."
        case "move_files":
            let n = (first.arguments["paths"] as? [String])?.count ?? 0
            return n == 1 ? "Moved it." : "Moved \(n) files."
        default: return nil
        }
    }

    /// "close this tab", "open Notes": the action in code, no model. Returns false to let the model handle the ask.
    private func runReflex(ask: String, ctx: ScreenContext, voice: Bool) async -> Bool {
        guard let r = Reflex.match(ask, links: ctx.links) else { return false }
        Log.info("reflex \(r.label) (no model call)")
        addStep(r.calls[0].statusText)
        let t = Date()
        var results: [String] = []
        for c in r.calls { results.append(await Tools.run(c, insertInto: ctx.pid)) }
        Log.time("reflex tool → \(results.joined(separator: ", "))", since: t)
        guard !results.contains(where: { $0.hasPrefix("error") }) else {
            Log.info("reflex failed; asking the model instead")
            return false
        }
        toolRanThisTurn = true
        let c = r.calls[0]
        noteOnTurn(c.name == "open_url" ? "Quicky did: opened tabs " + c.string("url") : "Quicky did: \(c.name) \(c.arguments) → \(results[0].prefix(120))")
        // The screen shows it happened; a spoken "Closed." only reads the action back.
        if voice { flushTTS() }
        return true
    }

    // MARK: - Confirm card

    private func confirmFromProgram(_ call: ToolCall) async -> Bool {
        flushTTS()
        addStep("Waiting for you to confirm")
        let ok = await askConfirm(tool: call)
        if let i = steps.indices.last { steps[i].state = ok ? .done : .error }
        if ok { addStep(call.statusText) }
        return ok
    }

    private func askConfirm(tool: ToolCall) async -> Bool {
        pendingTool = tool
        overlay = .confirm
        if !visible { show() }
        Log.info("confirm shown: \(tool.confirmTitle)")
        let ok = await withCheckedContinuation { confirmContinuation = $0 }
        Log.info("confirm \(ok ? "approved" : "declined")")
        return ok
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
        let th = Date()
        let result = try await ComputerUser.handoff(ask: ask, context: ctx, language: language)
        Log.time("cua handoff", since: th)
        switch result {
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
        case .done(let text, let actions):
            // Never claim success the agent didn't earn: with no actions, say what it said instead.
            if actions == 0 {
                appendAnswer(text.isEmpty ? "I couldn't do that on screen." : "I didn't do it: \(text)", voice: voice)
            } else {
                appendAnswer(handoff.spokenTemplate.isEmpty ? (text.isEmpty ? "Done." : text) : handoff.spokenTemplate, voice: voice)
            }
        case .stopped(let why):
            appendAnswer("Stopped: \(why).", voice: voice)
        case .failed(let why):
            throw NSError(domain: "cua", code: 1, userInfo: [NSLocalizedDescriptionKey: why])
        }
        if voice { flushTTS() }
    }

    /// Computer use has its own cursor and gives yours back after every click, so moving or clicking your
    /// mouse no longer stops it (Esc and the pill's Stop do).
    private func userMouse(dx: Double, dy: Double, clicked: Bool) {}

    // MARK: - Voice out (Bulbul or ElevenLabs)

    /// A TTS socket whose callbacks only act while it is the current one (a warm spare stays quiet).
    private func makeTTS(_ lang: String) -> TextToSpeech? {
        let t = TTS.make(language: lang)
        t.onAudio = { [weak self, weak t] pcm in
            guard let self, let t else { return }
            DispatchQueue.main.async {
                guard self.tts === t else { return }
                if !self.firstAudioLogged { self.firstAudioLogged = true; Log.time("first audio", since: self.turnStart) }
            }
            self.player.enqueue(int16: pcm)
        }
        t.onFinal = { [weak self, weak t] in guard let self, self.tts === t else { return }; self.ttsFinalReceived = true; self.playbackDrained() }
        t.onError = { [weak self, weak t] m in
            guard let self else { return }
            if self.warmTTS?.socket === t { self.warmTTS = nil }
            guard self.tts === t else { return }
            Log.error("tts: \(m)"); self.speakingEnded()
        }
        do { try t.connect() } catch { Log.error("tts connect: \(error.localizedDescription)"); return nil }
        return t
    }

    /// Opens the reply's Bulbul socket while STT finishes, in the language of the last voice turn, so the
    /// first sentence doesn't wait for a TLS + WebSocket handshake.
    private func prewarmTTS() {
        warmTTS?.socket.close()
        warmTTS = makeTTS(Sarvam.ttsLanguage(for: lastLanguage)).map { ($0, TTS.provider, Date()) }
    }

    /// One cheap request to api.sarvam.ai on fn-down, so the chat call reuses an open HTTPS connection
    /// (~50 ms of TCP + TLS saved, measured from Anup's Mac).
    private func warmConnection() {
        guard Date().timeIntervalSince(lastWarm) > 20 else { return }
        lastWarm = Date()
        ExtensionPicker.warm()
        DispatchQueue.global(qos: .utility).async { ExtensionHost.warm() }
        var hosts = [Sarvam.base]
        // Gemini answers on Vertex in Mumbai; a cold TLS connection there cost 0.3-3 s on the first answer.
        if Gemini.available, [Gemini.answerModel, Gemini.actionModel].contains(where: { $0.hasPrefix("gemini") }),
           let vertex = URL(string: "https://\(Gemini.location)-aiplatform.googleapis.com/") { hosts.append(vertex) }
        // Models Mumbai doesn't serve (3.8 Flash so far) answer from the global endpoint.
        if [Gemini.answerModel, Gemini.actionModel].contains(where: { $0.hasPrefix("gemini") && Gemini.locations(for: $0) != [Gemini.location] }),
           let global = URL(string: "https://aiplatform.googleapis.com/") { hosts.append(global) }
        if [Gemini.answerModel, Gemini.actionModel].contains(where: { $0.hasPrefix("aistudio/") }),
           let studio = URL(string: "https://generativelanguage.googleapis.com/") { hosts.append(studio) }
        if [Gemini.answerModel, Gemini.actionModel].contains(where: Anthropic.isClaude) { hosts.append(Anthropic.host) }
        if [Gemini.answerModel, Gemini.actionModel].contains(where: DeepSeek.isDeepSeek) { hosts.append(DeepSeek.host) }
        for url in hosts {
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 3
            URLSession.shared.dataTask(with: req).resume()
        }
    }

    private func startTTS(language: String?) {
        tts?.close()
        player.stop()
        let lang = Sarvam.ttsLanguage(for: language)
        let t: TextToSpeech
        if let w = warmTTS, w.socket.language == lang, w.provider == TTS.provider, Date().timeIntervalSince(w.at) < 20 {
            t = w.socket
        } else {
            warmTTS?.socket.close()
            guard let fresh = makeTTS(lang) else { warmTTS = nil; tts = nil; return }
            t = fresh
        }
        warmTTS = nil
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
        sentenceBuffer += tags.feed("", end: true).spoken
        if !sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { speakSentence(sentenceBuffer) }
        sentenceBuffer = ""
        tts.flush()
    }

    private func speakSentence(_ raw: String) {
        spokenChars += raw.count
        let clean = Self.cleanForSpeech(raw)
        // Bulbul rejects text with no letters ("2.", an emoji) and that error ends the whole utterance.
        // After an error tts is nil; setting speaking again would leave the panel stuck on Stop.
        guard tts != nil, clean.range(of: #"\p{L}"#, options: .regularExpression) != nil else { return }
        if !speaking { speaking = true }
        tts?.speak(clean)
    }

    nonisolated static func cleanForSpeech(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "the link", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_#>|]"#, with: "", options: .regularExpression)
        // Brackets go, except around an audio tag (only ElevenLabs turns still have any; see AudioTags).
        t = t.replacingOccurrences(of: #"\[(?![a-z ]{1,30}\])|(?<!\[[a-z ]{1,30})\]"#, with: "", options: .regularExpression)
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
        if !busy { steps = [] }      // the last answer's work log belongs to the chat it ran in
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
            typeInstead(chars)
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

    /// Typing or clicking the bar while listening: stop the mic and keep what was heard as the draft.
    func typeInstead(_ chars: String = "") {
        let text = partial
        discardPreroll()
        hotkey.resetGesture()
        input = .typed
        draft = (text.isEmpty ? "" : text + " ") + chars
        focusField = true
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
