# Quicky

Quicky is a menu-bar Mac app that sees the window you're in and answers by voice or text. Hold **fn**, ask, let go.
Sarvam is the ears, brain and voice (Saaras STT, sarvam-105b / gemma4, Bulbul TTS); OpenAI computer use
is the hands when an ask needs clicking. Specs are in `docs/` (ui-spec v4 is the visual source of truth).

## Build and run

```bash
./make-app.sh run        # swift build -c release → build/Assistant.app, signed, launched
tail -f build/assistant.log
swift test               # fn gesture machine, placement, router
```

Requires macOS 14+ and Xcode 16+ (Xcode 26 gets the real Liquid Glass `NSGlassEffectView`; older SDKs use
`NSVisualEffectView`).

## Keys

Open **Settings…** (⌘, from the menu-bar "?") and paste your keys. They're saved in the macOS Keychain
(service `dev.anup.assistant`) and used immediately; the window opens by itself on first run if no Sarvam
key is found. Alternatively, `export NAME=...` lines in `~/.zshrc` work too (an app opened from Finder
doesn't inherit your shell). Lookup order: Keychain → environment → `~/.zshrc` (last export wins).
Keys are never logged or shown back.

| Variable | Used for |
|---|---|
| `SARVAM_API_KEY` | STT, chat, TTS (required) |
| `OPENAI_API_KEY` | computer use (optional; without it those asks get a normal answer) |

Optional overrides (environment or `~/.zshrc`): `ASSISTANT_STT_MODEL` (saaras:v4), `ASSISTANT_VISION_MODEL` (gemma4),
`ASSISTANT_DEEP_MODEL` (sarvam-105b), `ASSISTANT_TTS_MODEL` (bulbul:v3), `ASSISTANT_TTS_SPEAKER` (shubh),
`ASSISTANT_TTS_PACE` (0.9; Settings → Voice speed wins), `ASSISTANT_CUA_MODEL` (gpt-6-astra), `ASSISTANT_CUA_FALLBACK_MODEL` (gpt-6.1-sol),
`ASSISTANT_SIGN_IDENTITY` (codesign identity for make-app.sh).

## First run: permissions

The menu-bar "?" menu shows ✓/✗ for each; click a ✗ to open its Settings pane.
Accessibility (read the screen, post clicks), Input Monitoring (fn), Screen Recording (window screenshot),
Microphone. macOS ties these grants to the code signature, so sign with a stable identity
(an "Apple Development" certificate is picked up automatically) or you'll re-grant after every build.

Demo Mac setup: System Settings → Keyboard → "Press 🌐 key to" = Do Nothing; move the Dictation shortcut
off the globe key; quit Kivi and Wispr Flow (they also listen to fn).

## Audio

With Bluetooth headphones (AirPods) as the default mic, Quicky records from the Mac's built-in mic instead, so the
headphones stay in high-quality mode; recording from them switches them into call mode and back, which glitches
the spoken answer. Playback also recovers by itself if the output device changes mid-answer.

## Gestures

| Gesture | Does |
|---|---|
| Hold fn | push-to-talk; release sends |
| Double-tap fn | hands-free; tap fn (or pause) to send |
| fn + Space, or shift + fn | type instead (shift + fn never turns the mic on); again while open closes it |
| Tap fn while open | closes it (or stops speech if it's talking) |
| fn while it's speaking | stops speech (hold to ask a follow-up) |
| Esc | close (stops speech, listening and the answer); on the confirm card it cancels, in a popover it closes the popover, during computer use it stops it |
| ⌘[ / ⌘] / ⌘N | previous / next / new chat |
| ⌘K | actions (copy, insert, read again, think harder, chats, look at another app) |
| ↵ on a typed answer | insert it into the field you were in |

Each summon continues the current chat if you used it in the last 2 minutes; after that it opens a new one (⌘[ goes back). Chats are saved to
`~/Library/Application Support/dev.anup.assistant/chats.json` (no screenshots).
To debug computer use, `defaults write dev.anup.assistant cuaDebug -bool true` saves each step's screenshot
with a ring where it acted to `…/dev.anup.assistant/cua-debug/` (local only, replaced every run).

## How a turn flows

fn down → mic + STT socket open and the front window is captured (AX + ScreenCaptureKit) before the
panel appears → release → `speech_end` → final transcript → rule-pass router →
- **fast**: gemma4 on `/v2` with the screenshot (falls back to on-device Vision OCR + sarvam-105b if the
  key isn't whitelisted for V2; the menu toggle "Use screenshots with gemma4" shows the state)
- **deep**: sarvam-105b, reasoning high
- **agent**: same plus tools (calendar, reminders, open, insert, move files, shortcuts, keyboard shortcuts, trim and join videos); data-changing
  tools show a confirm card first
- **computer**: sarvam-105b writes one instruction → confirm → OpenAI Responses `computer` loop with a
  executor with its own cursor (like Codex): it glides to each target and presses elements through
  accessibility, so your real cursor never moves and you can keep working; when a real click is needed it
  clicks and puts your cursor straight back. A pill shows each step; Esc or the pill's Stop ends it

Voice answers stream sentence by sentence into Bulbul over a WebSocket; stopping closes the socket
(there's no cancel message) and the chat remembers only what was heard.

## Probes (real APIs, from the terminal)

```bash
B=build/Assistant.app/Contents/MacOS/Assistant
$B --probe keys            # which keys were found (never prints them)
$B --probe chat "hi"       # sarvam-105b TTFT
$B --probe vision          # is gemma4 / V2 enabled for this key?
$B --probe tts "namaste" hi-IN
$B --probe stt 4           # speak for 4 s
$B --probe context         # what the model would see from the front app
$B --probe handoff "block this user"   # computer-use instruction only, never clicks
$B --probe gesture         # fn timelines through the state machine
$B --probe agent "close this tab" [v1]   # which tool the model picks (never runs it)
$B --probe cua-access     # can this OpenAI key use the computer-use models?
$B --probe cua-plan "block this user"   # the first real step computer use would take (never executed)
$B --probe stt-ws "close this tab"     # TTS speech streamed into the realtime STT socket (no mic)
$B --probe tts-dump "<text>" <out.wav>  # raw Bulbul stream: chunk sizes, headers, timing (no playback)
$B --probe audio-devices   # which mic it will record from
$B --probe media-test <dir>          # trim + join two synthetic clips with the video tool
$B --probe agent-fixture "<ask>"    # which tool the model picks for an ask in a fixed Finder context
$B --probe render <dir>   # offscreen PNGs of the panel states (nothing appears on screen)
```
