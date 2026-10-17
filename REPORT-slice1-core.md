# Slice 1 report: QuickyCore + `quicky`

## Result

Slice 1 is implemented: typed asks move through the pure `Session`/`Turn` reducers, stream Sarvam text through the actor-owned runner, commit revisioned chat history, project a `PanelScene`, and run headlessly through the JSON Lines CLI. `Package.swift`, the app target, `docs/`, `make-app.sh`, and `Info.plist` were not changed.

The implementation uses no `@unchecked Sendable`, `nonisolated(unsafe)`, or `@preconcurrency` escape hatch.

## Implementation notes

- `Session.handle(_:at:)`, `Turn.reduce`, and `ChatLog.apply` own the slice-1 state transitions.
- `Engine` stays on the main actor, starts actor-owned work without doing I/O in `send`, rejects completions without a live effect, and schedules gesture ticks from `Session.nextDeadline`.
- Sarvam uses `/v1/chat/completions`, explicit `reasoning_effort: null` for fast requests, SSE content deltas, cross-chunk `<think>` removal, one guarded key reload after a 401, and sanitized user errors.
- The system prompt SHA-256 is pinned by a test to `4d4c0b04ac3b66221b8b35af4edfe1525d378fa5460a9dd6e05595cd840de28a`.
- `Store` atomically writes one `state.json`; it checks the on-disk revision before writing, and process restarts continue at the next revision.
- Replay request bodies are exact after the fixture-declared `messages.0.content` volatile field is removed. A body fingerprint plus the CLI ask preflight covers a Foundation transport retry that can arrive without its already-consumed HTTP body. Unexpected requests, mismatches, and unconsumed expectations exit 1.
- `hello-hi` was seeded from a live `--record` run and split into two deterministic visible chunks. `cancel-long` was derived from a live recorded long answer; volatile wire metadata was removed and its recorded relative token pacing was rebased so the virtual 300 ms cancellation has a useful prefix.
- `--trace` prints request bodies but never request headers or keys.

## Verification

### Build

Command:

```text
swift build --disable-sandbox
```

Output:

```text
Building for debugging...
Build complete! (0.22 secs)
```

The two preceding SwiftPM cache warnings are caused by the managed sandbox making the user-level SwiftPM cache unwritable; the build completed.

### Tests

Command:

```text
swift test --disable-sandbox
```

Output:

```text
Test Suite 'QuickyCoreTests.xctest' passed at 2026-10-17 13:42:52.916.
     Executed 33 tests, with 0 failures (0 unexpected) in 0.647 (0.650) seconds
```

The tests cover the slice-1 phase and stage transitions, Fn timing, explicit-null reasoning, prompt hash, sanitizer, cross-chunk think removal, Store ordering, chat continuation/history/cap, cancellation/late output, sub-5 ms Esc dispatch, JSON ordering, panel projection, and replay mismatch failure.

### Core import lint

Command and result:

```text
$ scripts/lint-core-imports.sh
$ echo $?
0
```

The script produced no output.

### Deterministic hello replay

Each of three runs produced:

```jsonl
{"type":"session","chat":"c1","device":"fixture"}
{"type":"turn","ask":"Say hello in Hindi","chat":"c1","mode":"typed","route":"fast","turn":"t1"}
{"type":"token","text":"नम","turn":"t1"}
{"type":"token","text":"स्ते","turn":"t1"}
{"type":"done","outcome":"answered","retry":false,"total_ms":"*","ttft_ms":"*","turn":"t1"}
{"type":"quiet"}
```

The four pairwise diff files for hello and cancel were all empty:

```text
0 /tmp/slice1-hello-diff12.out
0 /tmp/slice1-hello-diff13.out
0 /tmp/slice1-cancel-diff12.out
0 /tmp/slice1-cancel-diff13.out
0 total
```

### Deterministic cancellation replay

Command used three times:

```text
quicky ask "Explain photosynthesis in detail, in at least ten sentences." \
  --provider replay:Fixtures/replay/cancel-long --cancel-after-ms 300
```

The end of each identical output was:

```jsonl
{"type":"token","text":" the","turn":"t1"}
{"type":"token","text":" chloroplast","turn":"t1"}
{"type":"token","text":"s","turn":"t1"}
{"type":"token","text":" of","turn":"t1"}
{"type":"token","text":" plant","turn":"t1"}
{"type":"token","text":" cells","turn":"t1"}
{"type":"token","text":",","turn":"t1"}
{"type":"token","text":" specifically","turn":"t1"}
{"type":"done","outcome":"cancelled","retry":false,"total_ms":"*","ttft_ms":"*","turn":"t1"}
{"type":"quiet"}
```

Exit codes: `2`, `2`, `2`.

### Two unauthorized responses

Command exited 1:

```jsonl
{"type":"session","chat":"c1","device":"fixture"}
{"type":"turn","ask":"hi","chat":"c1","mode":"typed","route":"fast","turn":"t1"}
{"type":"step","state":"done","text":"Reloaded the Sarvam key","turn":"t1"}
{"type":"error","message":"The Sarvam key was refused. Open Settings and check it."}
{"type":"done","outcome":"failed","retry":false,"total_ms":"*","ttft_ms":"*","turn":"t1"}
{"type":"quiet"}
```

There is exactly one reload notice, then a sanitized terminal failure.

### Live Sarvam and panel projection

Command:

```text
quicky ask "Say hello in Hindi" --panel
```

Output:

```jsonl
{"type":"session","chat":"c1","device":"fixture"}
{"type":"panel","scene":"panel thread=1"}
{"type":"turn","ask":"Say hello in Hindi","chat":"c1","mode":"typed","route":"fast","turn":"t1"}
{"type":"panel","scene":"panel thread=1"}
{"type":"token","text":"नमस्ते","turn":"t1"}
{"type":"panel","scene":"panel thread=1"}
{"type":"token","text":"।","turn":"t1"}
{"type":"panel","scene":"panel thread=1"}
{"type":"done","outcome":"answered","retry":false,"total_ms":230,"ttft_ms":210,"turn":"t1"}
{"type":"panel","scene":"panel thread=1"}
{"type":"quiet"}
{"type":"panel","scene":"panel thread=1"}
```

### Live same-store history

Two live commands used the same newly-created store directory. Both turns stayed in chat `c1`:

```jsonl
{"type":"turn","ask":"Reply with exactly: first","chat":"c1","mode":"typed","route":"agent","turn":"t1"}
{"type":"done","outcome":"answered","retry":false,"total_ms":306,"ttft_ms":293,"turn":"t1"}
{"type":"quiet"}
{"type":"turn","ask":"Reply with exactly: second","chat":"c1","mode":"typed","route":"agent","turn":"t1"}
{"type":"done","outcome":"answered","retry":false,"total_ms":179,"ttft_ms":166,"turn":"t1"}
{"type":"quiet"}
```

The second request's redacted-safe trace contained this real history segment before its newest user turn:

```json
{"content":"Reply with exactly: first","role":"user"},
{"content":"first","role":"assistant"},
{"content":"OUTPUT_MODE: typed\n\nASK: Reply with exactly: second","role":"user"}
```

Its persistence trace was `persist revision=2`.

## Commits

```text
fd582af Build slice-one state and prompt models
97aa18e Add streaming client runners and engine
a9404c3 Add deterministic replay CLI and fixtures
19fa9dd Cover slice-one reducers persistence and replay
4118738 Harden replay timing and persisted history
cfdf561 Keep shell device identity out of session defaults
```
