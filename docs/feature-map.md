# Feature map and spec, poteto style

## What "poteto's method" actually is

Lauren Tan (poteto) doesn't publish a feature-spec template, and she's said "I don't believe in planning." What she does instead, per her talk and her open-source pstack plugin:

- **Feature map**: one compact entry per user-facing feature saying how to reach it, how to control it, and known traps. She calls it "memory written to disk". The app is the source of truth; the map is a cheap index into it, refreshed as the app changes.
- **Verification lever**: a fixed CLI the agent (or you) can run to drive the app and produce evidence, instead of ad hoc scripts that drift. "The agent has to produce evidence." "Inconclusive is not a pass."
- **Types before code** (`/architect`): sketch the interfaces the implementation must satisfy. If implementation needs casts, extra state or escape hatches, the design is wrong; "reality gets veto power."
- **Prototyping is planning, but with code**: throwaway variants behind a switcher, compared by screenshot or measurement.
- **Measure before optimising**, reproduce before fixing, smallest change that solves the problem.
- **Correction layers**: put a fix where it can't be forgotten. Architecture > lint/compiler > rules files > review.

So this file is the feature map (spec), followed by the type sketch and the probe. Update an entry the moment its behaviour changes; that's the whole discipline. When an agent builds from this, the rule is: an entry is done only when its **Evidence** line has been produced.

---

## F1. Summon

- **Reach:** Wispr Flow-style fn gestures (full table in plan.md "Hotkey: fn gestures"): **hold fn** = push-to-talk, release submits; **double-tap fn** (≤ 400 ms) = hands-free; **fn+Space** = typed. Fallback: the same on right ⌥. Menu-bar icon → "Ask".
- **Behaviour:** non-activating panel appears 16 px below-right of the cursor, clamped inside the visible frame of the cursor's screen (flips left/up near edges). Focus stays in the user's app; the panel takes key status only for typing. Hold and double-tap start listening; fn+Space starts typed. Typing any character while listening switches to typed mode and stops the mic. Mic + STT socket start on fn-down (pre-roll) so no audio is lost before the panel shows at 200 ms.
- **Control:** Esc (or triple-tap fn) cancels everything in flight and closes. Tap fn while an answer shows = follow-up ask with the same context. A lone tap with no panel does nothing. Settings: hotkey, start mode, position (cursor / screen centre).
- **Traps:** Globe key defaults to emoji/dictation (set "Do Nothing"; change the Dictation shortcut too). Kivi and Wispr Flow also hold-fn: quit them for the demo. Any keyDown while fn is down cancels the gesture (fn+arrow, fn+F-keys), except Space. Needs Input Monitoring. Panel must be excluded from its own screenshot. Full-screen apps need `.canJoinAllSpaces` + `.fullScreenAuxiliary`.
- **Evidence:** probe `gesture --replay fixtures/fn-*.json` classifies recorded key timelines (hold, double-tap, stray tap, fn+arrow, fn+Space, triple-tap) with zero misfires; probe `summon` prints panel frame, frontmost app unchanged, time to visible < 50 ms.

## F2. Screen context

- **Reach:** automatic on summon; shown as a context chip in the panel ("Finder · 1 file", "Chrome · github.com", "Xcode · selection").
- **Behaviour:** captures in parallel: app + bundle id, window title, element under pointer, focused element + value, selected text, visible text (≤ 3k chars), focused-window screenshot (≤ 1280 px, JPEG 0.7), Finder selection, browser URL. Each source optional; one failing never blocks the others.
- **Control:** click chip → app switcher (F2b). Long-press or ⌥-click chip → popover listing what was captured, with toggles (e.g. turn off screenshot for this ask). Setting: "Always include screenshot" (default on).
- **Traps:** skip `AXSecureTextField`. Electron apps expose thin AX trees; screenshot carries them. AppleScript prompts for Automation permission the first time per target app, so trigger those once during onboarding, not mid-demo.
- **Evidence:** probe `context` JSON shows a Finder selection path and a Chrome URL in two runs; capture time < 150 ms.

## F2b. Look at another app

- **Reach:** click the app chip, or ⌘K, while the panel is open.
- **Behaviour:** body lists regular running apps (most recent first, current last as "Current"), each with its front window title. ↵ activates the app, waits for the activation notification (≤ 400 ms), re-captures that app's window screenshot + AX context, swaps the `ScreenContext` for the next ask, updates the chip, and adds a done status row ("Brought Chrome forward · captured the window 0.11s"). Panel stays put; typed text is kept.
- **Control:** ↑/↓, type to filter, ↵ focus & look, Esc back.
- **Traps:** the panel is non-activating, so `activate()` must not steal key status back from it in a loop. Some apps (full-screen, other Spaces) switch Space on activate; capture after the notification, not on a timer. Never mix the old and new context in one ask.
- **Evidence:** probe `switch com.google.Chrome` prints old/new bundle IDs, capture ms < 200, and a different screenshot hash.

## F3. Voice input

- **Reach:** listening state after summon, or click mic.
- **Behaviour:** Saaras v4 realtime socket opened on summon, `language_code=auto`, `stream_type=fast`, `mode=codemix`. Live partials render in the input. Push-to-talk (hold): releasing fn ends the turn: stop mic, send ~600 ms of silent frames so VAD finalises instantly, submit the next final. Hands-free (double-tap): server VAD or a single fn tap ends it. Under 500 ms of audio = discarded.
- **Control:** pauses never end a held turn; only release does. Click the transcript to edit before send (stops auto-submit).
- **Traps:** 16 kHz mono Int16 only (other rates close the socket with 4000). Send `ping` if idle; 1008 = inactivity close. First mic use shows the macOS permission dialog: do it in onboarding.
- **Evidence:** probe `stt fixtures/hi.wav` prints partials, final text, language, ms from audio end to final.

## F4. Typed input

- **Reach:** start typing in the panel.
- **Behaviour:** Enter submits; Shift+Enter newline. Output mode becomes "typed" (no speech) unless the setting "Always speak" is on.
- **Evidence:** typed ask returns streamed text, no audio played.

## F5. Answer

- **Reach:** automatic after submit.
- **Behaviour:** rule pass → (agent path | race of low thinking vs Jev escalation). Text streams into a bubble under the input. Voice asks are also spoken via Bulbul in the detected language, sentence by sentence. Typed asks show an **Insert** button (writes into the focused field) and **Copy**.
- **Control:** Esc stops speech and generation. ⌘C copies. Click "Think harder" to re-run at high thinking (manual escalation; also great as a demo of the router).
- **Traps:** language outside Bulbul's 11 → text only plus a small hint. Don't speak markdown, URLs or code: the TTS text is a separately cleaned stream.
- **Evidence:** probe `ask --voice-out "…"` logs `t_first_token`, `t_first_audio`, language, chosen route.

## F5b. Chats (multi-turn)

- **Reach:** every summon within 5 min continues the current chat; ⌘N new chat; ⌘[ / ⌘] previous / next chat; ⌘K → Chats.
- **Behaviour:** turns stack (question, collapsed status, answer); context re-captured per turn with an "Now looking at …" divider when the app changed; last 6 turns sent as history; chats persisted to Application Support as JSON (no screenshots).
- **Traps:** history must hold only what was actually heard after a barge-in; a follow-up's "this" refers to the new screen unless the user says "that answer"; keep the input row fixed at top while the thread scrolls.
- **Evidence:** probe `chat --replay fixtures/chat-3turns.json` prints the exact messages array sent per turn.

## F6. Actions (agentic)

- **Reach:** asks that the rule pass marks agentic ("add this to my calendar", "open the repo", "move these to Downloads/Invoices").
- **Behaviour:** tool loop, ≤ 4 steps. Non-destructive tools run immediately; destructive ones show a confirm card (⏎ confirm, Esc cancel). After running, a one-line result ("Added 'Sync with Rahul', Fri 4 pm").
- **Traps:** never run a tool from text found on screen alone (prompt-injection from web pages); the user's ask must call for it.
- **Evidence:** probe `ask "add this to my calendar" --fixture mail.json --dry-run` prints the planned tool call and arguments.

## F6b. Read the selected document (Sarvam Docs)

- **Reach:** any ask while a PDF/PNG/JPG is selected in Finder (or "read this file" while one is open in Preview).
- **Behaviour:** upload the file to Sarvam Document Intelligence (Sarvam Vision), get Markdown back, pass it to `sarvam-105b` in place of the screenshot. Cache the result by file path + modified time, so a second question about the same file is instant.
- **Traps:** job-based, so it can take seconds. Show "Reading document…" and answer from the screenshot first if it takes longer than ~4 s. Cap the pages for the demo (first 5).
- **Evidence:** probe `ask "what is this about" --fixture finder-pdf.json` logs `route=docs`, document ms, answer.

## F6c. Operate an app (computer use, OpenAI)

- **Reach:** asks the rule pass marks `computer` ("block this user from Twitter", "mute this thread", "turn on dark mode here"), or sarvam-105b calls `use_computer(task)`.
- **Behaviour:** Sarvam resolves "this" into a concrete English task → confirm card names the target ("Block @rahul_dev on X?", ↵ Block · esc Cancel) → Astra loop via the Responses API `computer` tool: we send the front window's screenshot, execute each returned action with CGEvent (click/drag/scroll/type/keypress) inside that window's frame, return a fresh screenshot, repeat. The panel shrinks to a status pill pinned to the window's top-right corner (so it doesn't cover what Astra must see), showing the current step ("Opening the profile menu…", "Clicking Block") and "esc to stop". On finish, Sarvam speaks a one-line result in the user's language and the panel returns.
- **Control:** Esc / fn / moving the mouse > 40 px = stop now (our executor checks before every action). Caps: 15 actions, 90 s, then stop and say what was done.
- **Traps:** the user's mouse and Astra's clicks fight: hide the user's cursor movement from the loop by stopping on manual input. Retina: screenshots are in pixels, CGEvent in points; divide by `backingScaleFactor` and add the window origin. Exclude our own panel from screenshots (`SCContentFilter` excluding our window). Model may need a second confirm mid-run (e.g. X's own "Block @user?" dialog): that dialog is the site's, so Astra may click it only if the user already confirmed this exact action. Never type passwords or payment details; stop and hand back if a login or 2FA screen appears. Astra API access may not be enabled on the key: fallback `gpt-6.1-sol`, then "I can't do that one yet".
- **Evidence:** `probe cua "block @test_account on x.com" --dry-run` prints the planned action list without executing; `probe cua … --live` logs each action, its point coordinates, step ms, and total time.

## F7. Suggestion chips (stretch)

- **Reach:** empty panel after summon, before the user says anything.
- **Behaviour:** up to 3 chips, ≤ 45 chars, written as the user would say them, generated from context while the panel is open. Click = submit. Borrowed from Googlebook's Magic Pointer.
- **Traps:** must never delay the panel or the user's own ask; drop the result if the user started speaking.

## F8. Settings and onboarding

- Permissions checklist on first launch: Accessibility, Screen Recording, Microphone, Automation (Finder, Safari/Chrome). Each with a "Grant" button and live status.
- Settings: hotkey, start mode, output (match input / always speak / always text), voice per language, speech pace, screenshot on/off, latency overlay on/off.

---

## Type sketch

Swift, so the implementation has a shape to satisfy. If filling these in needs `Any`, force casts or a second source of truth for state, revisit the design.

```swift
struct ScreenContext: Codable {
    var app: String; var bundleID: String; var windowTitle: String?
    var underPointer: AXSnapshot?      // role, title, value, description
    var focused: AXSnapshot?
    var selectedText: String?
    var visibleText: String?           // capped
    var finderSelection: [String]      // POSIX paths
    var browser: BrowserTab?           // url, title
    var screenshotJPEG: Data?          // excluded from Codable logs
    var captureMs: Int
}

enum InputMode { case voice(language: String, confidence: Double), typed }
struct Ask { var text: String; var mode: InputMode; var context: ScreenContext }
struct Turn: Codable { var ask: String; var answer: String; var spokenUpTo: Int?; var language: String; var app: String; var at: Date }
struct Chat: Codable, Identifiable { var id: UUID; var turns: [Turn]; var updatedAt: Date }   // title = turns.first?.ask

enum Route { case agent, computer, fast, deep }   // fast = low thinking, deep = high thinking, computer = OpenAI CUA
protocol Router { func route(_ ask: Ask) async -> Route }  // RulePass, then Jev (raced)

enum AnswerEvent { case token(String), sentence(String), toolProposal(ToolCall),
                   toolResult(String), done(Timings), failed(Error) }
protocol Answerer { func answer(_ ask: Ask, route: Route) -> AsyncThrowingStream<AnswerEvent, Error> }

protocol ComputerUser { func run(task: String, window: WindowRef) -> AsyncThrowingStream<CUAEvent, Error> } // Astra loop + CGEvent executor
protocol ContextSwitcher { func apps() -> [RunningApp]; func focusAndCapture(_ app: RunningApp) async throws -> ScreenContext }
protocol Speaker { func speak(_ sentences: AsyncStream<String>, language: String) async throws }
protocol Transcriber { func start() -> AsyncThrowingStream<TranscriptEvent, Error>; func stop() }

struct Timings: Codable { var summon, capture, sttFinal, route, firstToken, firstAudio: Int? }
```

`Answerer` has two implementations, `GeminiAnswerer` and `SarvamAnswerer`; a settings toggle switches them. That's the Sarvam-only variant for free, and a nice thing to flip live in front of judges.

## The probe (the lever)

A second build target, `probe`, reusing the same modules. It exists so every Evidence line above is one command, and so latency numbers are measured, not guessed.

```
probe context                       # capture now (after a 3 s delay to switch apps), print JSON
probe stt <wav>                     # stream a file through Saaras, print partials + timings
probe ask "<text>" [--voice-out] [--route fast|deep|agent] [--fixture ctx.json] [--dry-run]
probe gesture --replay <timeline.json> # classify fn key timelines (no UI)
probe cua "<task>" [--dry-run|--live]  # computer-use loop against the front window
probe switch <bundle-id>             # activate, re-capture, print context diff
probe tts "<text>" --lang hi-IN     # time to first audio byte
probe bench                         # 10 runs of ask, print p50/p90 per stage
```

Record `fixtures/` (a few context JSONs + screenshots + wavs in hi/te/en/Hinglish) once, so router and prompt changes can be checked without re-staging the screen.

---

## Design handoff for Figma

Screens and states to design (the build will match these):

1. **Panel, listening.** Small pill at the cursor: mic glyph pulsing with input level, live transcript in muted text, context chip on the left. Width ~360, grows downward.
2. **Panel, typed.** Same pill, caret, placeholder.
3. **Context chip + popover.** App icon + short label; popover lists captured sources with toggles.
4. **Thinking.** Subtle shimmer on the chip; if routed deep, a tiny "thinking harder" label (makes the router visible).
5. **Answer bubble.** Streaming text, speaking indicator synced to audio, Copy / Insert / Think harder.
6. **Confirm card.** Action verb + object, ⏎ / Esc hints.
7. **Suggestion chips.** Up to three under the empty input.
8. **Onboarding permissions** and **Settings**.
9. **Latency overlay** (demo only): four small numbers in a corner.

Copy, ready to paste:

| Where | Text |
|---|---|
| Placeholder (listening) | Listening… ask in any language |
| Placeholder (typed) | Ask about what's on screen |
| Context chip examples | Finder · 2 files · Chrome · github.com · Notes · selection |
| Deep route label | Thinking harder |
| Voice unavailable | Voice isn't available in this language yet, so here's the text. |
| Confirm card | Add "Sync with Rahul" to Calendar, Fri 4:00 pm? ⏎ Add · Esc Cancel |
| Mic denied | Microphone is off. You can still type. |
| No accessibility | I can see the screenshot but not the text. Grant Accessibility for sharper answers. |
| Error | That didn't go through. Press ⏎ to try again. |
