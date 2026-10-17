# Typed ask

The user types a question in the panel and presses Return. A spinner shows in the input row, and the answer streams into the thread under the question. Esc stops a running answer and keeps what has arrived. A failed ask shows a one-line error. Retry appears only when the failure was a transient network error. A refused key points to Settings.

## Sub-features

- `ask-stream` streams a typed question's answer token by token.
- `ask-cancel` stops a running answer with Esc and keeps the partial text.
- `ask-error` shows a sanitized error that never contains a key, with a footer action (Retry or Open Settings).
- `ask-retry` re-asks the last question after a transient failure.
- `ask-key-reload` re-reads the key once after a 401, then fails with "key was refused".

## How to get to it (user POV)

- fn+Space, type, Return.
- After an answer, fn+Space, type a follow-up, Return.
- After a transient failure, press Return (Retry) in the footer.

## Driving it with quicky and QuickyKeys

Preconditions:

- `swift build --product quicky` has run. For app steps, the doctor passes.

- **Deterministic stream.** Run `quicky ask "Say hello in Hindi" --provider replay:Fixtures/replay/hello-hi` three times. Each prints `session`, `turn`, two `token` lines (`नम`, `स्ते`), `done` with `"outcome":"answered"`, then `quiet`, and exits 0. The three outputs are byte-identical.
- **Deterministic cancel.** Run `quicky ask "Explain photosynthesis in detail, in at least ten sentences." --provider replay:Fixtures/replay/cancel-long --cancel-after-ms 300`. It ends with `done` `"outcome":"cancelled"` after the token `" specifically"`, and exits 2 every run.
- **Key refused.** Run `quicky ask hi --provider replay:Fixtures/replay/unauthorized-twice --key bad`. You see exactly one `step` saying "Reloaded the Sarvam key", then an `error` with a sanitized message, then `done` `"outcome":"failed"`, and exit 1.
- **Live Sarvam.** Run `quicky ask "Say hello in Hindi"`. It shows at least one `token` with Devanagari text, `done` `"outcome":"answered"` with real `ttft_ms`, and exits 0.
- **Real app engine.** Record the verify log's size, then run `quicky --app --run ta-$(date +%s) ask "Say hello in Hindi"` with that fresh run id. You get the same notice shape with `"device":"mac"`, and the log past the recorded offset holds the same lines for that id.
- **Physical.** Run `keys fn+space`, `keys type "Say hello in Hindi"`, then `keys return`. Within 10 s the verify log gets a `done` `"outcome":"answered"`, the TextEdit document stays empty, and TextEdit stays frontmost (lane 2 of `scripts/verify-slice1.sh`). Screenshot the panel. It shows the question in the thread with the answer below, and the input row empty.

## Gotchas

- Replay checks every request: model, `reasoning_effort: null`, the messages, and the system prompt's SHA-256. If you change the system prompt (`Prompt.system`), re-record or re-hash the fixtures. A mismatch exits 1 with an `error` line naming the field.
- Replay masks `ttft_ms` and `total_ms` as `"*"`. Live runs show real numbers.
- With no network, live runs fail with a transient error and `retry:true`. That's the Retry path, not a pass of `ask-stream`.
- `--key` overrides lookup only for that CLI process. The app reads the Keychain item `dev.anup.assistant` / `SARVAM_API_KEY`, then the environment, then `~/.zshrc`.
- `ask-retry` and `ask-cancel` through the panel aren't scripted yet. There's no replay fixture for a transient failure, and a transient failure can't be forced against the live app. The retry rule is covered by the core unit tests (`SessionTurnTests`). Report the panel paths for retry, cancel and the error footer as UNVERIFIED, not PASS.
