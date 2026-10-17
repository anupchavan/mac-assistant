# Quicky v2 design

This doc is the contract the rebuild is written against. If the code needs a parameter, flag, cast or second copy of state this doc doesn't have, the doc is wrong. Fix the doc first, then the code.

## Problem

Quicky v1 died of `AppModel.swift`: 881 lines with about 78 loose vars. Gesture meaning, listening, capture, the turn, speech, barge-in, confirmation, computer use, chats and panel flags all lived there, and every hard bug sat where two of them crossed. Examples: fn pressed while speaking, the Esc ladder, a double ↵ on a confirm card, a vision fallback after a tool had already acted, dismissal during our own app switch, history that should keep only what was heard.

v2 has to:

- run a whole turn headless through a JSON Lines CLI;
- keep the macOS shell thin;
- give each piece of state one owner;
- be built in five vertical slices, each proven on the real app before the next starts.

## Decisions, with evidence

**1. Swift, not Rust.** Both prototypes ran the same job: stream real Sarvam tokens, await a host callback mid-turn, cancel mid-stream. Both worked.

| | Rust + UniFFI | Swift QuickyCore |
|---|---|---|
| Incremental build after a one-line core edit | 24 s | 1.4 to 2.4 s |
| Clean build | 85 s | 14 s |
| Generated code | 2,272 lines | none |
| Swift 6 strict concurrency | needs a sed patch to the generated code, `@preconcurrency`, and 10 upstream escape hatches | zero diagnostics, zero escape hatches |
| Deployment target | forced to macOS 27 | macOS 14 |
| TTFT (network-bound) | 176 to 276 ms | 173 to 235 ms |

The Rust prototype's REPORT.md has the evidence. Rust would buy a language wall that keeps AppKit out of the core. A module wall does the same job: `QuickyCore` imports only Foundation, Security (Keychain) and Observation, and `scripts/lint-core-imports.sh` fails `make-app.sh` and `swift test` otherwise.

**2. One owner of behaviour, built from small reducers.** `Session` is a value with `mutating func handle(_ event: Event, at: Now) -> Reaction`. It does no I/O. Each sub-machine owns its own transitions:

- `Listen.reduce`
- `Speech.reduce`
- `Turn.reduce`
- `ChatLog.apply`
- `ComputerRun.reduce`

Each one mutates only its own value and returns typed intents. `Session.handle` holds only the rules that cross machines: barge-in, the Esc ladder, dismissal, and committing a turn. Three design runners (fable, opus, gpt-5.6-sol) converged on the pure-reducer shape independently. A gpt-6-astra cross-judge picked the opus candidate as the base (24/30 against 20 and 16). An interrogate panel (fable plus gpt-5.6-sol) then forced the splits and contracts below.

**3. A thin interpreter with owned runners.** `@MainActor Engine` is a dispatch table. It routes each `Effect` to the runner that owns that resource:

- `ChatRun`: one SSE request.
- `STTRun`: forwards the mic stream into the STT socket and owns finish ordering.
- `TTSRun`: one Bulbul socket plus its segment boundaries.
- `ComputerLoop`: the act/screenshot cycle.
- `DeviceCall`: one device request.

It tags every result with its `EffectID` and feeds it back as a `Completion`. Each runner has its own ordering tests.

**4. Isolation rules.** These are enforced by types, not prose.

- Only `Session.handle`, the `Engine` dispatch, and scene publication run on the main actor. `send` does no I/O and allocates no large buffers.
- Wire clients and runners are actors or `nonisolated`. SSE parsing, base64 and JSON happen off-main.
- `Device` is `Sendable` and non-main. `MacDevice` hops to the main actor only for AppKit calls that require it.
- Persistence goes to a serial `Store` actor, and the notice log to a `NoticeLog` actor. Both are async effects with monotonically increasing revisions.
- Test: with every device and client method blocked, `send(.escape)` and a key disposition still return within 5 ms.

**5. Cancellation is two contracts, not one.**

- *Streams and sockets* (chat, STT, TTS, mic, playback, the computer-use HTTP request) stop when their runner's `Task` is cancelled. Each runner acknowledges the stop with a completion, so the session knows the resource really stopped.
- *Effects* (`perform(ToolAction)`, `perform(ScreenAction)`) are atomic and never cancelled mid-way. A paste must restore the clipboard, and a click must release the button and restore the cursor.
  - If the user cancels while acting, `Turn.reduce` immediately commits the record with `outcome: unknown`.
  - When the effect finishes, its late completion reconciles that record and emits `action … late: true`. It is never re-run.
  - This guarantee holds within the process. There is no crash journal: a crash mid-effect is rare, v1 never handled it, and a journal earns its place only if it happens.

**6. The shell owns devices and pixels.** Panel window, event tap, AX/ScreenCaptureKit capture, mic, speaker, and the macOS side effects of tools. What fn *means* lives in the core (`FnGesture` moves there in slice 1), because it depends on core state: speaking means stop, a confirm card means ignore, computer use means stop.

**7. The panel is a projection.** `PanelScene(session)` is a pure function in the core, so the CLI can print it and assert on it. The shell keeps only its window, the draft text, scroll-follow and the overlay (⌘K, chats, apps).

## Usage

### CLI

```
quicky ask "Say hello in Hindi" --provider replay:Fixtures/replay/hello-hi     # slice 1, deterministic
quicky ask "Say hello in Hindi"                                                 # slice 1, live Sarvam
quicky ask "Explain photosynthesis" --cancel-after-ms 300                       # sends Esc at 300 ms
quicky ask --audio Fixtures/audio/hi-simple.wav --speak out.wav                 # slice 2
quicky ask "what is this file?" --context Fixtures/contexts/finder-pdf.json     # slice 3
quicky ask "add this to my calendar" --context Fixtures/contexts/mail-sync.json --confirm stdin   # slice 4
quicky ask "block this user" --context …/x-profile.json --screens Fixtures/screens/x-profile     # slice 5
quicky replay Fixtures/scripts/barge-in.jsonl                                   # timed input script
quicky --app --run r42 ask "what's selected?"                                   # same lines into a verify build of Quicky.app
```

Flags:

- `--provider live|replay:DIR`. Replay starts a loopback server that speaks HTTP/SSE *and* WebSocket. The core reaches it through `Config.baseURLs`, so it doesn't know. A replay directory is an ordered expectation set over method, endpoint, the decoded request body or client WS frames, and close behaviour. The server fails the run on any mismatch, unexpected request, or unconsumed expectation. Replay mode also drives a virtual clock that `Now`, replay pacing and `--cancel-after-ms` all read, so cancellation lands at the same point every run.
- `--key VALUE` overrides the key lookup (for the bad-key proof).
- `--panel` also prints `PanelScene` lines.
- `--trace` prints every effect and completion, with request bodies minus keys and images. It never prints key codes.
- `--store DIR` defaults to a temp dir.
- `--now ISO8601` pins the wall clock.

Exit codes: 0 answered or declined, 1 failed, 2 cancelled or stopped, 64 usage. The CLI exits on `quiet` (turn committed, speech drained or stopped, persistence done), not on `done`.

stdin carries input lines and stdout carries notice lines. The CLI, `quicky --app` and the app log all speak the same protocol through one codec, `QuickyCore/JSONL.swift`. Every input line may carry a `run` id, and every notice it causes echoes it.

A full slice-4 transcript. Lines starting with `>` are stdin. Timing fields are masked in golden comparisons.

```
$ quicky ask "add this to my calendar" --context Fixtures/contexts/mail-sync.json --confirm stdin --provider replay:Fixtures/replay/calendar
{"type":"session","chat":"c1","device":"fixture"}
{"type":"turn","turn":"t1","ask":"add this to my calendar","mode":"typed","route":"agent","app":"Mail"}
{"type":"step","turn":"t1","text":"Looked at Mail","state":"done"}
{"type":"proposal","turn":"t1","proposal":"p1","tool":"create_event","args":{"title":"Sync with Rahul","start":"2026-10-23T16:00:00+05:30","end":"2026-10-23T16:30:00+05:30"},"confirm":{"title":"Add “Sync with Rahul” to Calendar","detail":"Fri 23 Oct, 4:00–4:30 pm","verb":"Add to Calendar","destructive":false}}
> {"type":"confirm","proposal":"p1"}
> {"type":"confirm","proposal":"p1"}
{"type":"ignored","input":"confirm","detail":"no pending proposal p1"}
{"type":"action","turn":"t1","proposal":"p1","tool":"create_event","outcome":"done","result":"(recorded) event “Sync with Rahul” Fri 23 Oct 16:00–16:30"}
{"type":"token","turn":"t1","text":"Added “Sync with Rahul” for Friday at 4 pm."}
{"type":"done","turn":"t1","outcome":"answered","retry":false,"ttft_ms":"*","total_ms":"*"}
{"type":"quiet"}
```

Input lines: `ask`, `key` (raw `fn_down`, `fn_up`, `shift_down`, `key_down` with a code; never Esc), `escape`, `confirm`, `decline`, `command` (retry, think_harder, read_again, insert_answer, previous_chat, next_chat, new_chat, look_at), `dismiss`. Scripts can also use `wait` and `await` (driver only) and `voice` (CLI sugar: queue a WAV, then fn down, wait, fn up).

Notice lines: `session`, `listening`, `partial`, `heard`, `discarded`, `turn`, `step`, `token`, `proposal`, `action`, `speech`, `spoken`, `computer`, `done`, `quiet`, `panel`, `ignored`, `error`. The reducer returns notices explicitly in `Reaction`, so an input that changes nothing still says why. Keys that match nothing get `Disposition.silent`: no notice, no log line.

### Shell call sites

```swift
// Hotkey.swift, inside the CGEventTap callback. Esc never reaches engine.send as a key.
if code == kVK_Escape { return panelWindow.escape() ? nil : pass(event) }
guard fnHeld || flagsChanged else { return pass(event) }          // raw device bit, not gesture meaning
let d = MainActor.assumeIsolated { engine.send(.key(key)) }       // does no I/O; returns in microseconds
return d == .handled ? nil : pass(event)

// PanelViews.swift: the only turn-driving controls.
TextField(…).onSubmit { engine.send(.submit(draft)) }
Button(card.verb) { engine.send(.confirm(card.proposal)) }.keyboardShortcut(.return)

// PanelWindow.swift: the window follows the scene and never decides behaviour.
func observe() { withObservationTracking { apply(engine.scene) } onChange: { Task { @MainActor in self.observe() } } }
```

`fnHeld` is the physical state of the fn key from `flagsChanged`. Keeping it in the shell is deliberate: it stops every keystroke in every app from crossing into the core and the log. What a press *means* stays in the core.

## Module map

To trace a typed ask end to end, read three files: `PanelViews.swift` (submit), then `Session.swift` (what happens), then `Engine.swift` (how it touches the world).

`Sources/QuickyCore/` (imports allowlisted to Foundation, Security, Observation)

| file | owns |
|---|---|
| `Session.swift` | `Session`, `Phase`, `Input`, `Event`, `Effect`, `Completion`, `Reaction`; `handle` with the cross-machine rules and the phase table |
| `Turn.swift` | `Turn`, `Stage`, `Attempt`, `Turn.reduce` and the stage table |
| `Listening.swift` | `FnGesture` (moved from v1 unchanged, plus gap tests), `Listen`, `ListenStage`, `PrerollOrigin`, `SpeechGate`, silence deadlines, `Transcript.accept` |
| `Speech.swift` | `Speech.reduce`, `SpeechLedger`, `SentenceSplitter`, `cleanForSpeech` (keeps a spoken-to-answer span map), `ttsLanguage` |
| `Tools.swift` | `ToolName` (CaseIterable), with declaration and parser in one exhaustive switch; `ToolAction`; confirm policy and card copy |
| `Computer.swift` | `ComputerRun.reduce`: pixel-to-point mapping, outside-window refusal, 15-action cap, 90 s deadline, earned-success summary |
| `Prompt.swift` | `Router`, the `Plan` table, domain `ChatRequest`, context block, byte-stable prompt constants |
| `Chats.swift` | `ChatLog.apply`, `TurnRecord` (no image field exists), `Learned` (visionAvailable), `Store` actor (serial, revisioned `state.json`) |
| `Panel.swift` | `PanelScene` and its pure derivation |
| `Device.swift` | the `Device` protocol and every boundary value type |
| `Engine.swift` | `@MainActor @Observable` dispatch table, the task registry, the tick timer, `scene`; nothing else |
| `Runners.swift` | `ChatRun`, `STTRun`, `TTSRun`, `DeviceCall`: each owns one resource's lifetime and ordering |
| `Sarvam.swift` | `SarvamChat` (SSE), `SarvamSTT` (realtime WS plus REST fallback), `SarvamTTS` (Bulbul WS); wire structs private; base URLs from `Config` |
| `OpenAI.swift` | Responses computer-use client |
| `Keys.swift` | Keychain (non-interactive), then env, then shell rc files, last export wins; `reload()`; `Config.load()` |
| `Errors.swift` | `APIError` → `UserError`; the only error-to-text path, with the sanitizer |
| `JSONL.swift` | the line codec and driver (`run`); `serve` compiled only under `QUICKY_VERIFY` |

`Sources/quicky/`:

- `main.swift`: argv and stdin to `JSONL.run`.
- `FixtureDevice.swift`: fixture context and JPEG, WAV mic at virtual-clock pace, WAV speaker with a simulated playhead, recorded tools, PNG screen sequences.
- `ReplayServer.swift`: loopback HTTP/SSE and WebSocket replay with expectation matching.

The CLI does not link AppKit.

`Sources/QuickyApp/`:

| file | owns |
|---|---|
| `App.swift` | accessory app, menu bar, 2 s permission poll that rebuilds the hotkey tap, wiring, debug socket in verify builds only |
| `Hotkey.swift` | the `CGEventTap`: the `fnHeld` bit, raw keys to `engine.send`, Esc to `PanelWindow.escape()`, swallow by `Disposition`, re-enable on timeout, skip events tagged as ours |
| `PanelWindow.swift` | non-activating `NSPanel` and the pill, `PanelPlacer` (pure), `apply(scene)`, dismissal monitors, `escape()` |
| `PanelViews.swift`, `Theme.swift` | SwiftUI per ui-spec v4 |
| `MacDevice.swift` | `final class MacDevice: Device` with its stored parts; each capability file adds its requirements as an extension |
| `Capture.swift` | AX read (skips `AXSecureTextField`), SCK window shot, AppleScript context, Vision OCR, JPEG and PNG encoding |
| `Audio.swift` | `Mic` (16 kHz Int16 frames, Bluetooth to built-in mic) and `PCMPlayer` (22.05 kHz, device-change replay, drained resumes on stop) |
| `MacTools.swift` | `ToolAction` → EventKit, NSWorkspace, Process, FileManager, AVFoundation, Inserter, CGEvent shortcuts |
| `ScreenHands.swift` | computer-use executor, `AgentCursor`, tagged event source |
| `Settings.swift` | keys into Keychain, voice speed, right-Option toggle |

## The boundary

The shell talks to the core only through `engine.send(Input) -> Disposition` and by observing `engine.scene`. The core talks to the shell only through `Device`.

`Device` starts with **no requirements** in slice 1. Each slice adds its methods and, in the same change, real implementations in both `MacDevice` and `FixtureDevice`.

```swift
public protocol Device: Sendable {
    // slice 2: ears and mouth
    func startMicrophone() throws(DeviceError) -> AsyncStream<AudioFrame>  // 16 kHz Int16 LE, 100 ms frames plus rms; ends after stop flushes the tail
    func stopMicrophone() async
    func play(_ pcm: Data) async                     // 22.05 kHz Int16 LE, header stripped by SarvamTTS
    func stopPlayback() async -> PlaybackProgress    // clears at once; seconds played and scheduled
    func playbackDrained() async                     // also resumes when stopPlayback is called
    // slice 3: eyes
    func capture(_ request: CaptureRequest) async -> CaptureResult
    func recognizeText(in image: JPEGImage) async -> String
    // slice 4: hands (atomic: never cancelled mid-way)
    func perform(_ action: ToolAction) async -> ToolOutcome                 // .done(summary) | .failed(reason)
    func activate(_ app: AppRef) async
    // slice 5: computer-use hands
    func windowShot(of app: AppRef) async throws(DeviceError) -> WindowShot // PNG ≤1440 and the frame from the same capture
    func perform(_ action: ScreenAction, in shot: WindowShot) async -> ScreenActionOutcome
}

public struct CaptureResult: Sendable {
    public var context: ScreenContext?        // nil when nothing may be captured
    public var gaps: Set<ContextGap>          // .accessibility, .screenRecording, .ownApp, .secureFieldSkipped
    public var target: CaptureTarget          // pid plus CGWindowID: the identity reuse is keyed by
}
```

Rules:

- Images cross already encoded: JPEG ≤1280 at q0.7 for chat, PNG ≤1440 for computer use. No CoreGraphics type enters the core.
- Wire types are `internal` to their client files.
- `ScreenHands.perform` re-reads the target pid, window id and frame immediately before every HID event, and refuses with `.refused(reason)` if any has changed.
- Mouse sequences release the button and restore the cursor in `defer`.

## State machines

The `// S2` to `// S5` tags mark the slice that adds a case or field. Slice 1 compiles without them, and when a later slice adds a case, the compiler lists every switch it has to extend.

```swift
struct Session: Sendable, Equatable {
    private(set) var phase: Phase = .hidden
    private(set) var speech: Speech = .silent            // S2, orthogonal to phase
    private(set) var chats: ChatLog
    private(set) var learned: Learned                    // S3, persisted
    private var gesture = FnGesture()                    // S1: fn+Space opens typing in slice 1
    private var screen = ContextSlot()                   // S3: one capture per summon, keyed by CaptureTarget
    private var focus = FocusGuard()                     // S4: expects a specific AppRef activation
    mutating func handle(_ e: Event, at now: Now) -> Reaction
}
struct Reaction { var effects: [Effect]; var notices: [Notice]; var disposition: Disposition }   // .handled | .notHandled | .silent

enum Phase { case hidden, typing(prefill: String), turn(Turn), resting, listen(Listen) /* S2 */ }
struct Listen { let id: EffectID; let origin: PrerollOrigin; var stage: ListenStage; var partial: String; var gate: SpeechGate }
enum ListenStage { case preroll, open(ListenMode), transcribing }
enum PrerollOrigin { case fromHidden, fromResting, fromSpeech }   // replaces v1's shownBeforeHold and tapStoppedSpeech

struct Turn { let id: TurnID; let ask: Ask; var context: ScreenContext?; var answer: String; var steps: [Step]; var stage: Stage }
enum Stage {
    case streaming(EffectID, Attempt)
    case capturing(EffectID), reading(EffectID, ScreenInput)          // S3
    case confirming(Proposal), acting(Proposal, EffectID)             // S4
    case handingOff(EffectID), computing(ComputerRun)                 // S5
}
enum Attempt { case first(ChatModel, reloadedKey: Bool), afterAction(ActionReceipt, reloadedKey: Bool) }
enum Outcome { case answered, declined, cancelled, stopped(String), failed(UserError, retry: Bool), unknown(ActionID) }
```

Invariants:

- **Whether a tool has acted is read from the stage, never stored twice.** `acting` and `afterAction` both mean it has. At commit, `Turn.reduce` computes `retry` from the stage. A failure during `streaming(.first)` with a transient error is retryable. A failure during `acting` commits `unknown`. A failure during `afterAction` retries the *follow-up request* once with the same receipt. That request uses `tool_choice: none` and can't call a tool, so the retry can't produce a second `perform`.
- **The v2-to-OCR vision fallback** matches only `streaming(.first(.visionV2))` with an empty answer.
- **401 handling:** a `Completion.unauthorized` while `reloadedKey == false` emits `reloadKeys` then the same request with `reloadedKey: true`. A second 401 commits failed.
- **Confirms:** a confirm matches only in `.confirming(p)` with `p.id`, so a second ↵ is `ignored`.
- **No persisted images:** `TurnRecord` has no image field.
- **Context reuse:** a capture is reused only within the same summon interaction, and only if its `CaptureTarget` (pid plus window id) matches. A regular-app activation invalidates the slot.
- **Heard history** (protocol confirmed by the slice-2 spike, see Risks):
  - `TTSRun` sends each sentence as `text` plus `flush`, and counts the server's `final` events as segment boundaries in order.
  - `SpeechLedger` maps each segment to its span of the answer through `cleanForSpeech`'s span map.
  - On a stop, history keeps the segments whose `final` arrived and whose audio had fully played (cumulative scheduled seconds at that boundary ≤ played seconds), then appends "…(interrupted)".
  - If the spike shows Bulbul doesn't emit one ordered `final` per flush, the fallback is: history keeps the whole answer only if speech drained, else the answer up to the last confirmed boundary, else "(interrupted before speaking)".
  - Either way, it never claims more than was heard.
- **Persistence order:** heard-range updates trigger a second persist after `spoken`.

### Phase table (`Session.handle`)

| from | input | to | effects |
|---|---|---|---|
| hidden | gesture `.typed` (fn+Space) | typing("") | summon chat; capture (S3) |
| hidden, resting | gesture `.preroll` (S2) | listen(preroll, origin) | capture; sttOpen; micOn; speechStop if speaking (origin `.fromSpeech`) |
| any non-listen phase | gesture `.preroll`, `.holdBegan`, `.holdEnded`, `.tap` (slice 1) | unchanged | `silent` |
| turn(not confirming) | gesture `.preroll` (S2) | listen(preroll, .fromResting) | Turn.reduce(cancel); speechStop |
| turn(confirming) | gesture `.preroll` | unchanged | `ignored` (the card needs ↵ or Esc) |
| turn(computing) | gesture `.preroll` or Esc | resting | ComputerRun stops before its next action; commit stopped |
| listen(preroll) | `.holdBegan` / `.handsFree` | listen(open) | panel appears by derivation |
| listen(preroll, o) | `.tap`, `.discard`, `.holdEnded` < 500 ms | o's discard phase | micOff; sttClose |
| listen(open) | release, hands-free stop, silence deadline | listen(transcribing), or discard if no speech | `STTRun.finish`: forward the mic tail, then speech_end |
| listen(transcribing) | gesture `.preroll` | listen(preroll, origin kept) | sttClose; the old transcript is dropped |
| listen(transcribing) | transcript accepted | turn(new, voice) | Turn.reduce(start) |
| listen(any) | printable key | typing(prefill: partial) | micOff; sttClose |
| hidden, typing, resting | submit(text) | turn(new, typed) | speechStop if speaking; Turn.reduce(start) |
| turn(acting) | submit, chat switch | unchanged | `ignored` until the effect settles |
| resting | Esc | speaking: resting plus speechStop; silent: hidden | |
| turn(not acting) | Esc | resting | Turn.reduce(cancel) |
| turn(acting) | Esc | resting | Turn.reduce(cancel): commit `unknown`; the effect finishes and reconciles |
| hidden | Esc | hidden | `notHandled` (Esc passes to the app) |
| resting, typing | dismiss(d) | hidden | only if not speaking, not scrolled up, and `focus` doesn't expect d's app |
| resting | command(retry) | turn(same ask, .retry) | only if the last record has `retry: true` |
| resting | other commands | per command | think harder: a new deep turn; chat moves: ChatLog.apply; `look_at` (S3): capture that app's window without activating it |

### Stage table (`Turn.reduce`, abbreviated)

| from | event | to | effects |
|---|---|---|---|
| start | context fresh for this target, or before slice 3 | per `Plan`: streaming, reading, or handingOff for computer | chat or OCR; open TTS if voice |
| streaming | token | streaming | answer += token; `say` each complete sentence if voice |
| streaming(.first(vision)) | vision refused, answer empty | reading(ocr) | learned.vision = false; recognizeText |
| streaming | ended, no tool call | commit answered | flush speech; persist |
| streaming | ended, tool call needs confirm | confirming(p) | proposal notice |
| streaming | ended, tool call without confirm | acting | perform |
| confirming(p) | confirm(p.id) | acting | perform; focus.expect(app) if it activates one |
| confirming(p) | decline or Esc | commit declined | |
| acting | performed | streaming(.afterAction) | follow-up resends tools with `tool_choice: none`, 300 tokens |
| any awaiting | failed | commit failed (retry per the invariants) | stop the rest |
| handingOff | handoff JSON | ask the user, confirming, or computing | |
| computing | step results | loop, or commit summary or stopped | 15 actions, 90 s, refuse outside the window, never claim unearned success |

**One Esc path.** The tap maps the Esc key to `PanelWindow.escape()` before anything else. That closes an open overlay if there is one, else it calls `engine.send(.escape)`. The panel's own key monitor handles Esc only when no tap exists at all. A listen-only tap still counts as existing, which matches v1.

## Verification lever

- **CLI, deterministic.** `quicky` with `FixtureDevice` and `--provider replay:DIR`, on the virtual clock. Replay validates requests as well as serving responses, so a wrong prompt, a missing `reasoning_effort: null` or a missing WS control frame fails the run. Golden comparisons mask timing fields. Recorded SSE comes in slice 1, and recorded STT and TTS WebSocket sessions in slice 2, all through the same loopback server. This runs in CI and in Codex's sandbox.
- **CLI, live providers.** The same command with `--provider live` proves the real Sarvam and OpenAI calls.
- **Real app, engine path.** `./make-app.sh verify` builds the same bundle, signed with the same identity, with `QUICKY_VERIFY` defined. That build serves the JSON Lines socket (mode 0600, plus a per-launch token printed to the log). Release builds have no socket. `quicky --app --run ID` sends the same lines in. The verifier records the log offset first, waits for that run's `quiet`, asserts the ordered suffix for its run id, then waits 2 s to check no forbidden notice follows. This proves real capture, real EventKit and CGEvent, and the real panel.
- **Real app, physical path.** The event tap, fn timing, panel ↵ and Esc, and outside-click dismissal sit below the socket, so they get their own gate: a Codex `gpt-6-astra` wrapper presses real keys and screenshots the panel. Slice 1 ships a minimal version of that driver (fn+Space, type, ↵, Esc) before the slice is accepted. The full verify-quicky skill and its feature map are written right after slice 1.

## Where the v1 traps live

| trap | home |
|---|---|
| 401 means the key changed | `Completion.unauthorized` → `reloadKeys` plus one guarded retry |
| raw bodies or key-like strings shown | `Errors.swift` is the only text path; sanitizer test |
| a Finder-launched app has no shell env | `Keys.swift` rc parser, last export wins; Keychain reads use `kSecUseAuthenticationUIFail` |
| mic streams before the STT handshake | `SarvamSTT` outbox, flushed on open |
| slow handshake | `STTRun.finish`: 1.5 s open wait, 3 s final wait, REST fallback with the full buffer |
| mic tail clipped by speech_end | `STTRun` forwards until the mic stream ends, then sends speech_end |
| our own close fails the pending receive | `SarvamSTT` close reason `.closedByClient` |
| first mic chunk is the fn click | `SpeechGate` seeds the noise floor from it |
| "thank you" hallucinated on near-silence | `Transcript.accept` when voiced < 800 ms |
| AirPods flip to call mode | `Mic` picks the built-in input when the default input is Bluetooth |
| TTS has no cancel message | `TTSRun` stop closes the socket |
| 450-char pieces, RIFF header, 11 languages | `SarvamTTS`, `ttsLanguage` |
| output device change drops the queue | `PCMPlayer` replays unplayed buffers |
| drain wait leaks after a stop | `playbackDrained` resumes on `stopPlayback` |
| sentence splitting (danda, "3.5") | `SentenceSplitter` tests |
| barge-in remembers only what was heard | `SpeechLedger` (above) |
| `/v1` needs tools with tool messages | `ToolUse.forbidAfterResult`; replay expectation checks the encoded request |
| `reasoning_effort` omitted means thinking on | `Reasoning.off` encodes JSON null; there is no omit case |
| `<think>` inline in content | `SarvamChat` stream filter |
| system prompt must be byte-stable for caching | `Prompt` constant; hash test |
| vision fallback or retry after a tool acted | derived from `Stage` and `Attempt` (above) |
| ordinary words like "like" and "click" over-route; one-word asks | `Router` fixture tests |
| tool list and parser drift apart | `ToolName.spec`, one switch; round-trip test |
| an activation we caused dismisses the panel | `FocusGuard` expects one `AppRef` and clears on its activation; 3 s leak guard |
| Esc handled twice | Esc maps to `escape()` in the tap; the panel handles it only with no tap |
| AX children inherit a 6 s timeout | `Capture`: 50 ms per element, 80 ms total |
| SCK cost and first-capture warm-up | `Capture`: 5 s content cache, `warmUp()` at launch |
| AppleScript can't be cancelled | `Capture`: 150 ms deadline, busy skip |
| panel or overlay in screenshots | capture runs at preroll before the panel shows and targets another pid's window; `AgentCursor.sharingType = .none` |
| secure fields (v1 never handled them) | `Capture` skips `AXSecureTextField` and reports `.secureFieldSkipped`; canary test |
| clicking a window that moved or changed | `ScreenHands` revalidates pid, window and frame before every HID event |
| cancelled click leaves the button down | `ScreenHands` defer: mouse-up and cursor restore |
| cancelled paste loses the clipboard | `perform` is atomic; never cancelled |
| AX press first, hover-click, keys to the target pid, synthetic tag | `ScreenHands` |
| tap disabled, or created before the grant | `Hotkey` re-enables; `App` rebuilds on a permission change |
| slow tap callback disables the tap | `send` does no I/O (the 5 ms test above) |
| safety checks; fallback model | `OpenAI.swift` |
| unearned computer-use success | `ComputerRun.summary` |
| ad-hoc signing loses grants | `make-app.sh` stable identity for both release and verify builds; launch with `open` |
| core imports AppKit | `scripts/lint-core-imports.sh` |
| fn conflicts with Kivi, Wispr, the globe key | README setup section (kept from v1) |
| Liquid Glass corners, masks, caret, partial markdown, bottom-aligned thread | `PanelWindow`, `PanelViews` |

## Slices

| slice | adds | CLI proof | app proof |
|---|---|---|---|
| 1. Typed ask, streamed text | package, lint, `make-app.sh` (release and verify); core Session (hidden/typing/turn/resting), Turn (streaming `.first`, cancel, fail, retry, 401 reload), FnGesture with the slice-1 rows, Chats and Store, Prompt (system prompt, router, typed plan), SarvamChat, ChatRun, Keys, Errors, Panel, Device (empty), JSONL; CLI main, empty FixtureDevice, ReplayServer (HTTP/SSE); app App, Hotkey, PanelWindow, PanelViews, Theme, MacDevice (empty), Settings; minimal physical driver | replay `hello-hi`: at least 2 `token` lines, `done answered`, `quiet`, identical across 3 runs with timing masked; replay with `--cancel-after-ms 300` gives `done cancelled` at the same token every run, exit 2; replay `unauthorized-twice` with `--key bad` gives one reload then `done failed` with sanitized text; live: `done answered` | physical: fn+Space over another app opens the panel at the cursor; type, ↵, tokens stream; the front app is unchanged; Esc closes. Engine path: `quicky --app --run r1 ask` gives the same notices for `r1` |
| 2. Voice | listen and speech machines, barge-in, SpeechGate, SpeechLedger (after the Bulbul `final`-per-flush spike), SarvamSTT and SarvamTTS, STTRun and TTSRun; ReplayServer WebSocket; Device mic and playback; FixtureDevice WAV I/O; app Audio | replay `hi-simple`: `heard hi-IN`, `speech`, `spoken`, `quiet`; a barge-in script gives `spoken interrupted:true` with heard < total; a silence WAV gives `discarded` and no chat request (replay fails on any unexpected request); a delayed-open replay keeps the pre-open audio | hold fn, speak, release, hear the answer; fn mid-answer stops speech within 100 ms and the panel stays; AirPods use the built-in mic |
| 3. Screen context | capturing and reading stages, keyed reuse, vision-refusal fallback, context block, Learned; Device capture and OCR; app Capture | `--context finder-pdf.json` gives `Looked at Finder` and an answer that names the file; replay checks the image part; vision refused gives OCR plus v1; context from app A is never reused after switching to app B | over a Finder PDF, "what is this?"; `look_at` Finder; Screen Recording revoked gives an AX-only answer with `gaps` reported; secure-field canary text appears nowhere in the log, trace or requests |
| 4. Tools with confirm cards | Tools, confirming and acting stages, FocusGuard, follow-up; Device perform and activate; app MacTools | the transcript above; a double confirm gives one `action` plus `ignored`; `--confirm no` gives declined; Esc during a slow recorded tool gives `done unknown`, then a late `action`, and no second perform | Mail, "add this to my calendar", card, ↵, the event exists; ↵ twice gives one event; insert keeps the clipboard |
| 5. Computer use | Computer, OpenAI, handingOff and computing stages; Device windowShot and screen actions; app ScreenHands, pill | fixture screens give `computer` lines with points inside the frame; the caps stop it; "Click." never routes to computer; no key gives "isn't set up"; a moved-window fixture gives `refused` | a local fixture app (not a real account): card, ↵, pill, AX press, real cursor unmoved, Esc stops within one action |

## Tradeoffs accepted

- We accept a session on the main actor in exchange for synchronous swallow decisions with one owner of gesture meaning. It's safe only because `send` does no I/O, and a test enforces that.
- We accept the shell keeping one raw bit (`fnHeld`) in exchange for not routing and logging every keystroke on the Mac.
- We accept that the core knows UI vocabulary (steps, footer actions, presence), though not pixels, in exchange for CLI assertions on the panel.
- We accept a verify-only socket in exchange for driving the real signed app through the CLI protocol. Release builds have no socket.
- We accept in-process at-most-once effects (`unknown` plus a late reconcile) in exchange for never duplicating an event, a file move, a paste or a click. We decline a crash journal until a crash mid-effect is observed.
- We accept conservative heard-history in exchange for never claiming the user heard something they didn't.
- We accept a loopback replay server (more code than a `URLProtocol`) because `URLSessionWebSocketTask` bypasses `URLProtocol`, and slice 2 needs deterministic sockets.

## Alternatives rejected

- **Rust + UniFFI.** Measured above.
- **Linear async turn** (`Core.ask -> AsyncStream`, the prototype shape). It hides only the turn. Barge-in, the Esc ladder, dismissal and confirm idempotency would fall to the shell as flags, which recreates `AppModel`.
- **Session actor with the gesture and panel machines in the shell** (the fable candidate). The fact "this press stopped speech" lived in both the core and the panel. That is split ownership.
- **Fixture-only CLI with no path into the real app** (the gpt-5.6-sol candidate). Permission-gated behaviour would be provable only by hand. Its request-matching replay and effect-safety ideas were grafted in here.
- **A stored `MutationFence` beside `Stage`.** Two fields that must agree. Derived from the stage instead.
- **Out-of-process core (XPC).** IPC on every audio frame and token, for no gain. TCC still belongs to the app.

## Risks

- Settled by a spike on 2026-10-17 (bulbul:v3, hi-IN, three sentences, four runs): Bulbul sends one `final` per `flush`, in order, and every audio frame of a segment arrives before that segment's `final`. Per-sentence flushing costs nothing measurable: first audio arrived at about 300 ms either way (one 877 ms outlier), and all audio was in by 1.2 to 1.75 s for 5.5 s of speech. No RIFF headers were seen, but the strip stays. The ledger below is built as specified, and its fallback is not needed.
- SwiftUI may re-render the whole thread per token. Batch scene publishes to about 30 Hz if profiling shows jank.
- Private and incognito windows have no reliable detector across browsers. v2 does not claim to skip them.
- The live CLI and the verify app share Sarvam and OpenAI credits. CI uses replay only.

## Open questions for the operator

These are product calls where ui-spec v4 and v1's final code disagree. The defaults below apply unless you say otherwise.

1. Chat continue window: **5 minutes** (ui-spec) vs 120 s (v1 code).
2. Moving the mouse during computer use: **ignore it, since the agent has its own cursor** (v1's final decision) vs stop at 40 px (ui-spec v3). fn and Esc always stop it.
3. Short-hold discard: **500 ms** (v1 code) vs 300 ms (spec).
4. Bundle id: **keep `dev.anup.assistant`** so Keychain items and TCC grants carry over.

## Next implementation step

Create the package (QuickyCore, quicky, QuickyApp) with the import lint. Then write `Session.handle` and `Turn.reduce` for slice 1, with one test per table row that feeds scripted completions, before `SarvamChat` exists.
