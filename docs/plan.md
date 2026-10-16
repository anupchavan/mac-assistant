# A Mac assistant that sees your screen and speaks your language

Working name only. Researched 16 Oct 2026, ~16:45 IST, before the BYOP Buildathon.
Companion files: [feature-map.md](feature-map.md) (the spec, poteto style), [ui-spec.md](ui-spec.md) (every pixel of the panel), [prompts.md](prompts.md) (every prompt and schema, incl. Sarvam Code UI build prompts). Figma: https://www.figma.com/design/0lkGMSXVtQ5FmnsOUZ6y9t

## Update 16:57 IST: Sarvam stack only, and Kivi

The organisers' resources (Sarvam key from indus.sarvam.ai, Sarvam docs, Kivi) point to a Sarvam-only build. **The Sarvam-only variant below is now the default**; Gemini and Jev are dropped.

**Kivi** ([heykivi.ai](https://heykivi.ai/)) is Sarvam's own Mac app, free in alpha, macOS 14+. You hold fn to dictate and polished Hindi/English/Hinglish text lands in any app. You hold fn+⌃ for "hey kivi" commands: rewrite the selection, draft a reply from what's on screen, answer a question. It also remembers corrections and applies tone per app. No developer API is mentioned.

What that changes:
- **Positioning.** Kivi is "you talk, kivi types": the output goes into a text field. Ours is "you ask, it looks and talks back, or acts". Speech comes back out (Bulbul), it reasons about the whole screen (Finder selection, element under the pointer, browser), and it takes actions. Pitch it as the other half of Kivi, or "the feature I'd want to ship in Kivi next". It's the best possible framing for a PPI, because it shows you used their product and found the gap.
- **Hotkey.** *(Updated 18:00 IST: back on fn, Wispr Flow-style. See "Hotkey: fn gestures" below.)* Kivi and Wispr Flow both listen to hold-fn, so on the demo Mac quit them (or move their key) before going on stage. Right ⌥ stays as the settings fallback.
- **Don't compete on dictation.** Typed answers still get an Insert button, but dictating into fields is Kivi's job; don't demo it.
- **Install Kivi before the demo** and use it for 5 minutes. The judges will ask how this differs.

## Update 17:05 IST: which parts of Indus to use

The banner at the venue lists Indus ("everything you need to build with AI"): Cowork, API, Studio, Docs, Voice, Code. The emails promise credits "for Sarvam Code and APIs". Plan per product:

| Indus product | Use it? | How |
|---|---|---|
| **API** | **Yes, core** | Key from indus.sarvam.ai/key-management. Saaras v4 (voice in), Bulbul (voice out), `gemma4` (screenshot questions), `sarvam-105b` (hard questions, agent loop). Every model call in the app goes here. |
| **Code** (Sarvam Code) | **Yes, to build the app** | Their coding agent (early beta, planner → worker → verifier). Build the app with it during the build-along and say so on stage. The feature map goes in as the planner's input, and each entry's Evidence line plus the probe CLI gives the verifier something real to check. This is poteto's method running on Sarvam's own agent. Keep Claude/Cursor as a backup if the beta is flaky. |
| **Docs** (Document Agents / Sarvam Vision) | **Yes, one feature** | When the Finder selection is a PDF or image, send the file itself to Document Intelligence instead of relying on the screenshot. "ఈ ఫైల్ దేని గురించి?" on a selected PDF then reads the real document, tables included. It's slower (job-based), so show a "Reading document…" state. |
| **Kivi** | **Yes, as the reference** | Install it, use it to dictate prompts to Sarvam Code, and position the app as its complement (see above). |
| **Studio** (voice cloning) | Stretch | Instant Voice Cloning (beta, 12 Indian languages) could give the assistant one signature voice in every language. Only if slices 1–6 are done. |
| **Voice** (Voice Agents, phone) | No | Built for phone-call agents at ₹3.50/min, not a desktop app. Mention it as the "call your Mac from your phone" future, nothing more. |
| **Cowork** | Ask at the booth | No public description found. If it exposes an agent or task API, it could replace our hand-written tool loop. |

## What the rules actually allow

The emails say "use Sarvam AI's APIs" and nothing more. No Sarvam-only clause, no platform clause, so a Mac-only app is fine. The judging panel is the Sarvam team, though, and the prize is API credits, so the safe reading is: Sarvam must be visibly load-bearing. In the default build Sarvam owns the voice in, the voice out and the language detection, which is the part of the demo people remember. Ask at the 30-minute Q&A whether (a) non-Sarvam LLMs are OK and (b) code written before 17:00 is OK. Both answers change the plan below; the Sarvam-only variant is ready either way.

## The pitch, in one line

Hold fn (or tap it twice) anywhere on your Mac, ask about what's on screen in Telugu, Hindi, Hinglish or English, and hear the answer back in the same language. The screen can be in English; the conversation doesn't have to be. That's the Indic angle no Raycast or Googlebook ships, and it's exactly Sarvam's thesis.

## Pipeline

```
fn down ──► [0 ms] mic + STT socket start (pre-roll, discarded if it was a stray tap)
hold 200 ms / 2nd tap ──► panel at cursor ┬─► capture context (parallel, ~60–150 ms)
                                          │     screenshot of focused window (ScreenCaptureKit, downscaled)
                                          │     AX: app, window title, focused element + value, selected text,
                                          │         element under the pointer, visible text (capped)
                                          │     Finder selection / browser URL (AppleScript, only if frontmost)
                                          ├─► TTS socket + LLM connection warm (STT already open)
                                          └─► (optional) suggestion-chips call, warms the LLM connection
user speaks ──► Saaras v4 realtime (language_code=auto, stream_type=fast, mode=codemix)
                partials shown live; release fn (hold) or VAD / fn tap (hands-free) ──► final transcript + language
   or types ──► Enter
                                          ▼
                    Rule pass (≤1 ms, regex + context)  ──► agentic? ──► Agent path (tools, thinking=medium)
                                          │ no
                                          ▼
              RACE: start Gemini Flash (thinking=low) immediately
                    and ask Jev in parallel; if Jev says "high" within 300 ms, abort and restart at high
                                          ▼
                 stream tokens ──► sentence splitter ──► Bulbul TTS socket (voice in) ──► audio out
                                                  └──► panel text (always), "Insert" button (typed in)
```

### Why the race instead of a sequential router
A router in series adds its full latency to every request, including the 80% that didn't need it. Racing means the common case pays nothing for Jev; only escalations pay a restart, and those are the requests where the user expects a pause anyway. If Jev turns out to be slow or flaky at the venue, delete it: the rule pass plus low thinking is a complete product.

### Caching, honestly
Gemini's implicit cache only applies above a 4,096-token shared prefix on Gemini 3.x; explicit caches (1 h default TTL, settable to days) reportedly want ~32k tokens and cost storage per hour. A normal system prompt is ~1–2k tokens, so "cache the system prompt for days" buys nothing as stated. Two options:

- **Default:** grow the static prefix past 4.1k tokens with things that genuinely help (tool docs, 10–15 few-shot examples, per-app playbooks for Finder/Safari/Chrome/VS Code/Mail), keep it byte-identical, put screenshot + query last. Implicit caching is then automatic and free.
- Skip explicit caching entirely for the hackathon.

Either way, caching is not where TTFT lives. The screenshot is.

## Latency / TTFT budget

Target: first audio < 1.2 s after the user stops talking; first text token < 700 ms after Enter.

| Stage | Budget | How |
|---|---|---|
| Panel visible after the gesture is recognised (200 ms hold or 2nd tap) | < 50 ms | Pre-created `NSPanel`, just reposition + `orderFront` |
| Context capture | < 150 ms, hidden | Starts on hotkey, finishes while the user is still talking |
| STT final after speech end | ~300–600 ms | `stream_type=fast`; lower `silence_duration_ms` to ~350 if it feels sluggish |
| Rule pass | < 1 ms | Regex |
| LLM first token | 300–600 ms | Screenshot ≤ 1280 px long edge, JPEG q≈0.7; low media resolution if the API exposes it; HTTP/2 connection kept warm |
| TTS first audio | ~200–400 ms | Send first sentence the moment it closes; `min_buffer_size` small (~30), `flush` at sentence end |

Tricks, in order of payoff:
1. Capture on hotkey, not on submit. The user's speaking time hides all capture cost.
2. Downscale the screenshot. Image tokens dominate prefill.
3. Keep sockets and the HTTPS connection warm from fn-down.
4. Ask the model to put a short direct answer first (prompt does this), so the first TTS sentence is short.
5. Speculative: if the final transcript equals the last partial, you could have fired the LLM on the partial. Skip unless everything else is done.

Measure each stage with timestamps and show the numbers on stage (see the probe in feature-map.md). Judges trust a TTFT number on screen more than "it's fast".

## Language handling

- STT with `language_code=auto` returns `language` + `language_confidence` on finals. Saaras covers 23 languages.
- Bulbul TTS covers 11 (hi, bn, ta, te, kn, ml, mr, gu, pa, od, en-IN). If the detected language is outside that set, answer in text in that language and speak a one-line English/Hindi note, or just show text. Default: text only, with a small "voice not available for this language" hint.
- Hinglish/codemix: `mode=codemix` keeps the transcript natural. Reply in the same mix (prompt rule), speak with `hi-IN`.
- Typed input: detect script with a cheap check (Devanagari/Telugu/etc. Unicode ranges); Latin script → reply in the language the text is in, leave it to the model.

Model-version note: the models page lists Bulbul v3, while the streaming-TTS guide uses `bulbul:v4-flash`. Try v4-flash first; fall back to v3.

## Agentic path (wrappers, not a framework)

Tools are thin wrappers over things macOS already does. Each is ~10 lines of Swift calling `NSWorkspace`, AppleScript (`NSAppleScript`/`osascript`), `shortcuts run`, or `CGEvent`.

| Tool | Wraps | Confirm? |
|---|---|---|
| `open_url(url)` | `NSWorkspace.open` | no |
| `open_app(name)` | `NSWorkspace` | no |
| `reveal_or_open_file(path)` | Finder AppleScript | no |
| `insert_text(text)` | AX `setValue` on focused element, else paste via ⌘V | no (user sees it) |
| `copy_to_clipboard(text)` | `NSPasteboard` | no |
| `create_reminder(title, due?)` / `create_event(title, start, end)` | Reminders/Calendar AppleScript | yes |
| `run_shortcut(name, input?)` | `shortcuts run` | yes |
| `move_files(paths, dest)` / `rename_file` | Finder AppleScript | yes |
| `web_search(query)` | open search URL, or Gemini grounding | no |

Loop: Gemini with function calling, max 4 steps, each tool result appended, destructive ones gated by a confirm card in the panel ("Create event 'Sync with Rahul' Fri 4 pm? ⏎ / Esc"). That confirm card is also a nice demo moment.

## Context capture details (the Raycast-level polish)

| Signal | API | Permission |
|---|---|---|
| Frontmost app, bundle id | `NSWorkspace.shared.frontmostApplication` | none |
| Window title | AX `kAXFocusedWindowAttribute` → `kAXTitleAttribute` | Accessibility |
| Focused field + value | `kAXFocusedUIElementAttribute`, `kAXValueAttribute`, role | Accessibility |
| Selected text | `kAXSelectedTextAttribute` on focused element (no clipboard) | Accessibility |
| Thing under the pointer | `AXUIElementCopyElementAtPosition(systemWide, x, y)` → role, title, value, description | Accessibility |
| Visible text | walk focused window's AX tree, depth ≤ 8, cap ~3k chars | Accessibility |
| Screenshot | ScreenCaptureKit `SCScreenshotManager` on the focused window, exclude own panel | Screen Recording |
| Finder selection | `tell application "Finder" to get POSIX path of (selection as alias list)` | Automation (per app) |
| Browser URL/title | Safari: `URL of current tab of front window`; Chrome/Arc: `URL of active tab of front window` | Automation |

Skip secure text fields (`AXSecureTextField`) entirely. Never send background-tab content.

"Element under the pointer" is the Magic Pointer idea without the wiggle: the panel opens at the cursor, so the cursor is pointing at the thing the user means. Put it first in the context block.

## Update 18:35 IST: computer use goes to OpenAI (GPT-6 Astra)

Decision (Anup): when an ask needs the Mac to be *operated* ("block this user on Twitter", "unsubscribe from this", "rename these tabs' group"), the turn is handed to OpenAI's computer-use model. Sarvam stays the ears, brain and voice; Astra is only the hands.

- **What exists (checked 16 Oct):** the Responses API has a built-in `computer` tool. The model returns `computer_call` items with an ordered `actions` list (`click`, `double_click`, `drag`, `move`, `scroll`, `keypress`, `type`, `wait`, `screenshot`); our app executes them and answers with `computer_call_output` carrying a base64 PNG screenshot, chained by `previous_response_id`. If we downscale the screenshot we must map coordinates back. ([OpenAI computer-use guide](https://developers.openai.com/api/docs/guides/tools-computer-use))
- **Which model:** GPT-6 Astra launched 3 Sep 2026 (OSWorld 2.0 72.6%; $10 / $50 per M in/out tokens) and lists computer use as a supported tool, but API access was rolling out to trusted organisations first ([The Neuron, 4 Sep 2026](https://theneuron.ai/news/gpt-6-astra-everything-you-need-to-know-about-openais-new-model/)). The guide's own `computer` tool examples use `gpt-6.1-sol` and recommend code execution for Astra. **Default: `gpt-6-astra` with the `computer` tool; if the key gets a model or tool error, fall back to `gpt-6.1-sol`.** Verify with `probe cua --dry-run` before the demo; this is the first thing to test when keys arrive.
- **Why the `computer` tool and not code execution:** on the user's real Mac we want every action to pass through our own executor, so we can gate, log, preview and stop it. Code execution would hand the model a PyAutoGUI shell on the user's machine.
- **Routing:** the rule pass gets a `computer` route (UI verbs aimed at an app or site with no native tool: block, mute, unfollow, report, unsubscribe, archive, like, follow, "click", "turn on/off", "go to settings"). Native tools (calendar, files, open URL) stay on the Sarvam agent path because they are faster and deterministic. sarvam-105b can also escalate mid-turn by calling `use_computer(task)`.
- **Handoff:** Sarvam rewrites the ask into a one-line English task with the resolved target ("Block the X/Twitter account @rahul_dev shown in the focused Chrome tab"), using UNDER_POINTER and the AX context so "this user" is concrete. Astra never sees the user's raw voice; the result comes back to Sarvam, which says it in the user's language.
- **Safety, not optional:** confirm before the first consequential click (block/delete/send/buy/post), showing the exact target. Hard caps: 15 actions, 90 s. Screen text is untrusted. Only the window that was frontmost at summon is in scope; any action outside its frame is refused. Esc, fn, or moving the mouse more than 40 px stops the run instantly.
- **Rules risk:** the event brief says "use Sarvam AI's APIs". Pitch it honestly: everything the user hears and says runs on Sarvam; the one thing Sarvam doesn't offer (pixel-level computer control) is delegated. Ask at the booth if unsure.

## Hotkey: fn gestures (Wispr Flow-style)

Copied from how Wispr Flow does it, because judges will already have the muscle memory. Flow: hold fn = push-to-talk, release pastes; double-tap fn = hands-free, double-tap again (or fn+Space) stops; Esc cancels; recordings under ~0.5 s are dropped; double-tap and early-cancel windows are 0.5 s ([Flow docs](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free)).

| Gesture | What it does | Ends the turn |
|---|---|---|
| **Hold fn** (≥ 200 ms) | Panel at cursor, listening. Push-to-talk. | **Release fn.** Submits immediately, no waiting for VAD silence. |
| **Double-tap fn** (2nd press ≤ 400 ms after 1st release) | Panel at cursor, listening, hands-free. | Server VAD silence, **or tap fn once**, or click the mic. |
| **fn + Space** | Panel at cursor in **typed** mode (mic off, answer typed back). | ↵ |
| **Tap fn while the panel shows an answer** | Follow-up: listen again with the same screen context. | as above |
| **Esc** / triple-tap fn | Cancel: stop speech → cancel generation → close. | |
| A lone single tap | Nothing (too easy to hit by accident, and waiting to rule out a double-tap would add 400 ms). | |

Why hold is the default demo gesture: release is a perfect end-of-speech signal, so it removes VAD's ~500 ms trailing-silence wait from TTFT. Hands-free is for long or rambling asks.

Latency trick: on **every** fn-down, start the mic and open the Saaras socket at once and buffer audio (pre-roll). If it turns out to be a hold or a double-tap, nothing was lost; if it was a stray tap, discard the buffer and close the socket silently. Show the panel at the 200 ms hold mark or on the second tap.

End-of-turn on release: stop sending mic audio, then send ~600 ms of silent frames so Saaras's server VAD finalises right away (works whether or not the socket exposes an explicit flush), and take the next `transcript.final`. Recordings under 500 ms are discarded, as in Flow.

Detection: `CGEventTap` on `flagsChanged` + `keyDown`, watching `.maskSecondaryFn` (needs Input Monitoring permission). Any `keyDown` while fn is down cancels the gesture (so fn+arrow, fn+F-keys and fn+Delete never trigger), except Space, which is the typed chord. Swallow nothing: we only observe, so the system still gets fn.

macOS setup before the demo: Keyboard → "Press 🌐 key to" → **Do Nothing**; Keyboard → Dictation → Shortcut → anything except "Press 🌐 twice" / "Hold 🌐"; quit Kivi and Wispr Flow. Settings fallback: the same gestures on right ⌥.

## Stack defaults (where the plan forked)

- **Native Swift/SwiftUI menu-bar app**, not Electron/Tauri. Accessibility and ScreenCaptureKit are first-class in Swift and painful elsewhere; a non-activating `NSPanel` is the only way to float an input without stealing focus from the app you're asking about.
- **Direct REST/WebSocket calls**, no SDKs, to avoid fighting package managers on venue Wi-Fi. `URLSessionWebSocketTask` for both Sarvam sockets.
- **API keys in a gitignored `Secrets.swift`** for the hackathon.
- **Mic capture:** `AVAudioEngine` tap → convert to 16 kHz mono Int16 → base64 → `audio_input` events.
- **Audio out:** request `linear16` (or mp3) from Bulbul, play via `AVAudioPlayerNode` buffer queue.

## Sarvam-only variant

If the Q&A says Sarvam models only:

| Role | Default build | Sarvam-only |
|---|---|---|
| STT | Saaras v4 | same |
| TTS | Bulbul | same |
| Vision + chat (fast) | Gemini Flash, low thinking | **`gemma4`** on `POST https://api.sarvam.ai/v2/chat/completions` (image as base64 data URI, streaming, tools) |
| Hard / escalated | Gemini Flash, high thinking | **`sarvam-105b`** with `reasoning_effort: "high"` (text only: feed it AX text + gemma4's one-paragraph screen description) |
| Voice-chat no-image questions | Gemini | `sarvam-105b-conversations`, `reasoning_effort: null` |
| Router | rules + Jev | rules + a heuristic (see prompts.md); no extra model call |
| OCR fallback | n/a | Sarvam Vision (Document Intelligence). Likely job-based and slow, so only when AX text is empty |

Gotchas: V2 chat is beta and **needs per-key whitelisting**; ask the Sarvam team to enable it on your key in the first 15 minutes. Request body cap is 10 MB (fine at 1280 px JPEG). `max_tokens` defaults to 2048 and reasoning tokens count against it; set `reasoning_effort: null` on the fast path or the answer can come back empty. Auth header is `api-subscription-key` (Bearer also accepted). Remote image URLs are rejected; base64 only.

This variant is arguably the stronger pitch for this room: "every model in this app is served by Sarvam".

## Build order for the 60-minute build-along

Each slice ends in something you can show, so if time runs out you stop at a working demo, not a half-wired one. If pre-built code is allowed, do slices 1–3 before 17:00 and spend the session on voice and polish.

1. Hotkey + panel at cursor, typed input, Esc closes. *Evidence: panel opens over Finder without stealing focus.*
2. Context capture printed as JSON. *Evidence: probe shows selected Finder file + window title.*
3. Typed question → LLM stream → text in panel. *Evidence: answers "what's this file?" correctly.*
4. Mic → Saaras partials in panel → final → LLM. *Evidence: Hindi question transcribed live.*
5. LLM sentences → Bulbul → audio. *Evidence: Hindi answer spoken; TTFT logged.*
6. Rule pass + one tool (`create_event` or `open_url`) with confirm card.
7. Jev race, suggestion chips, settings. Only if 1–6 are solid.

## Demo script (90 seconds)

1. Finder, a PDF selected. Hold fn and ask in Telugu, release: "ఈ ఫైల్ దేని గురించి?" → spoken Telugu summary. Point at the context chip: "Finder · 1 file selected".
2. Chrome on an English news article, Hinglish: "isko 3 lines mein samjhao" → spoken Hinglish.
3. Mail with a meeting date. fn + Space, type "add this to my calendar" → confirm card → ⏎ → event created; typed input gets typed output.
4. Flash the latency overlay: STT 410 ms, first token 520 ms, first audio 890 ms (whatever is real).

## Sources

- Sarvam models, chat, Gemma 4, STT realtime, TTS streaming: [models](https://docs.sarvam.ai/api/getting-started/models.md), [chat completion](https://docs.sarvam.ai/api/api-guides-tutorials/chat-completion/overview.md), [gemma4](https://docs.sarvam.ai/api/getting-started/models/openweight/gemma-4-31b.md), [STT realtime](https://docs.sarvam.ai/api/api-guides-tutorials/speech-to-text/realtime-streaming.md), [TTS websocket](https://docs.sarvam.ai/api/api-guides-tutorials/text-to-speech/streaming-api/web-socket.md)
- Gemini caching: [Google docs](https://ai.google.dev/gemini-api/docs/caching?lang=rest), [fast.io summary](https://fast.io/resources/gemini-context-caching.md) (third-party; the 32k explicit minimum and 3.8 Flash prices come from here and are unverified)
- Jev: [OpenRouter listing](https://openrouter.ai/typesafe/jev-router)
- Raycast: [Screen Awareness manual](https://manual.raycast.com/ai/screen-awareness)
- Magic Pointer: [SlashGear](https://www.slashgear.com/2187274/googlebook-magic-pointer-ai-feature-explained/), [Chrome Unboxed teardown](https://chromeunboxed.com/googlebooks-magic-pointer-app-teardown-gives-us-a-glimpse-under-the-hood/)
