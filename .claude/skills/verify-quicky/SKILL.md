---
name: verify-quicky
description: Drive the real Quicky menu-bar app (macOS, Swift) and its JSON Lines CLI to prove a feature works, with evidence. Use before declaring any Quicky change done, to reproduce a Quicky bug, or when asked to verify, test or screenshot Quicky. Covers the headless `quicky` CLI (replay and live Sarvam), the verify build's socket, and real keystrokes through the event tap.
---

# Verify Quicky

Quicky is an accessory (menu-bar) app. fn+Space opens a non-activating panel at the cursor. You type a question, and the answer streams in from Sarvam. There are four ways to drive it. Use the cheapest one that reaches the behaviour you're proving, and name the one you used in your evidence.

| path | proves | needs |
|---|---|---|
| `quicky ask … --provider replay:DIR` | core behaviour, deterministic | nothing (no network, no app) |
| `quicky ask …` (live) | the real Sarvam call | the Sarvam key (Keychain or `~/.zshrc`) |
| `quicky --app …` | the real signed app's engine, panel and store | verify build running |
| `QuickyKeys.app` + `scripts/verify-slice1.sh` | the physical path: event tap, key panel, focus | verify build running; QuickyKeys allowed to post events |

The feature map in `features/` is the recipe source. Read `features/README.md` first.

## Launch

From the repo root:

```bash
swift build --product quicky          # the CLI, at .build/debug/quicky
./make-app.sh verify run              # build/verify/Quicky.app (QUICKY_VERIFY) plus build/verify/QuickyKeys.app, relaunched
```

Building writes `.build/` and `build/`, and that is expected. `run` relaunches only the bundle it just built, so a release Quicky the user started from elsewhere keeps running. Release and verify share a bundle id and the fn hotkey, though, so stop the user's release build (ask first) before driving a verify build.

The app is ready when `~/Library/Application Support/dev.anup.assistant/quicky.sock` exists. That takes under 2 s after `running, logs: …` prints. The verify build keeps its own chats in `~/Library/Application Support/dev.anup.assistant/verify/` and its notice log in `~/Library/Logs/Quicky/verify.log`, so it never touches the user's real chats. It starts empty the first time. Delete that directory to start from empty again.

The CLI needs no launch. Each `quicky ask` is its own process with a temporary store, unless you pass `--store DIR`.

## Doctor

```bash
scripts/quicky-doctor.sh
```

It changes no state (the socket check sends an empty ask, which the engine ignores) and prints `ok`/`FAIL` per check: the verify app from this checkout is running, exactly one Quicky process exists, the socket and token are mode 600, the CLI is built, QuickyKeys may post events, and the engine answers over the socket. Run it first, and again whenever anything looks off. Don't drive the app while any line says FAIL.

## Drive

- **CLI.** `.build/debug/quicky ask "TEXT" [--provider replay:Fixtures/replay/NAME] [--cancel-after-ms N] [--key K] [--store DIR] [--panel] [--trace] [--run ID]`. It prints one JSON notice per line and exits on `quiet`. Exit codes: 0 answered, 1 failed, 2 cancelled, 64 usage. `--trace` shows request bodies (never keys). `--panel` prints the derived panel state after each notice. Input lines on stdin work too (see `docs/design.md`, Usage).
- **Real app engine.** `.build/debug/quicky --app --run ID ask "TEXT"`, or `… --app --run ID send` with input lines on stdin, for example `{"type":"key","key":"fn_down"}`, `{"type":"command","command":"new_chat"}` or `{"type":"escape"}`. It prints only that run's notices. Exit 4 means the input was `ignored`, and the line says why. Exit 3 means it timed out.
- **Real keys.** `open -n -W -g build/verify/QuickyKeys.app --args fn+space | fn-hold <ms> | fn-tap | esc | return | type <text> | check`. These go through the same session event tap a keyboard does. Computer-use tools have no fn key, and they send keystrokes to a named app, which skips Quicky's key panel. So use QuickyKeys for anything typed into the panel.
- **Panel visible?** Count on-screen windows owned by `Quicky`: `swift -e 'import CoreGraphics; let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]; print(l.filter { ($0["kCGWindowOwnerName"] as? String) == "Quicky" }.count)'`. The answer is 1 when the panel is up and 0 when it's hidden.
- **Front app.** `osascript -e 'tell application "System Events" to name of first process whose frontmost is true'`. Quicky must never become frontmost.
- **Whole slice in one go.** `scripts/verify-slice1.sh` runs the six slice-1 lanes over TextEdit and prints `PASS`/`FAIL` per lane. A non-zero exit means at least one lane failed.

## Evidence

Put everything for one run under `build/verify/evidence/<run-id>/`. It's gitignored and survives cleanup.

- CLI: the exact command, stdout (the notices), and the exit code.
- App engine: the `quicky --app` stdout, plus the matching suffix of `~/Library/Logs/Quicky/verify.log`. Record the byte offset before you act and grep for your `run` id, so stale lines can't pass.
- Physical: the `verify-slice1.sh` output, and `screencapture -x build/verify/evidence/<run-id>/<step>.png` right after each visible step. A screenshot without Screen Recording permission for your shell shows only Quicky's own window over black. That's enough to prove the panel state.
- Side effects: check them with a second, read-only view. Examples: the TextEdit document's text through `osascript`, the chat id in a later `turn` notice, `state.json` in the verify store.

Proof standard: drive the user's path (fn+Space, typing, Return, Esc), not an internal setter. Capture the action and the resulting state, not just the final frame. Inconclusive is not a pass. Replay proves the core only; it never proves the Sarvam call or the app.

## Cleanup

```bash
pkill -f "$PWD/build/verify/Quicky.app/Contents/MacOS/Quicky"   # kills only the verify build this checkout started
```

Close only the TextEdit documents your run opened. The recipes close their own document at the end, and `verify-slice1.sh` does too. Never close documents you didn't create. Leave `build/verify/evidence/` in place. Remove `~/Library/Application Support/dev.anup.assistant/verify/` only when you need an empty start. Never touch `~/Library/Application Support/dev.anup.assistant/state.json`: that's the user's real history. Never `pkill -x Quicky`, because the user may be running their own release build.

## Helpers

- `scripts/quicky-doctor.sh`: the doctor above.
- `scripts/verify-slice1.sh`: the six physical slice-1 lanes.
- `scripts/keys.swift`: the source of QuickyKeys.app, built by `./make-app.sh verify`.
- `scripts/lint-core-imports.sh`: fails if `QuickyCore` imports anything beyond Foundation, Security or Observation.
