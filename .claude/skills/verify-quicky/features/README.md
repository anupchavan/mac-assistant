# Quicky verification map

This directory is the maintained source for verifying what a Quicky user can do. Read this index before you drive the app, then use the matching feature file as the recipe. It was built from the running app at the end of slice 1 (typed asks). It is not built from the old v1 spec. Add a file when a slice lands.

## Baseline preconditions

- Run `swift build --product quicky` and `./make-app.sh verify run` from the repo root.
- `scripts/quicky-doctor.sh` prints only `ok` lines.
- The verify store `~/Library/Application Support/dev.anup.assistant/verify/` is empty, or holds only chats this run created.
- TextEdit is installed. The recipes use it as the "other app" that must stay frontmost.
- Never drive a Quicky this run didn't start. The doctor's first two checks enforce that.

## Driving conventions

- `quicky` means `.build/debug/quicky`. `keys` means `open -n -W -g build/verify/QuickyKeys.app --args`.
- Use replay for core behaviour, live for the Sarvam call, `--app` for the real engine and store, and `keys` for anything a person does with the keyboard.
- Pass a fresh `--run` id to every `quicky --app` call, and grep the notice log by that id.
- Treat every command as literal. Keep quoted text unchanged.

## Proof and skip reporting

- CLI proof is the command, its stdout and its exit code.
- App proof is the run's notices from `quicky --app` or the notice log, plus a screenshot of the panel.
- Physical proof is the `verify-slice1.sh` lane lines, plus the read-only side-effect checks they print.
- Record the feature file and entry point with every artifact, under `build/verify/evidence/<run-id>/`.
- When an entry point is unreachable, report it with the command you tried and the reason. Never report it as verified through another path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behaviour. It then has exactly four H2 sections, in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with quicky and QuickyKeys`, `Gotchas`.

## Features

- [Summon and dismiss](./summon-and-dismiss.md) covers fn+Space, Esc, toggling, outside clicks, and keys that pass through to other apps.
- [Typed ask](./typed-ask.md) covers a streamed answer, cancel mid-answer, errors and retry.
- [Chats](./chats.md) covers the follow-up memory, the 5-minute continue window, persistence across relaunch, and chat navigation.
