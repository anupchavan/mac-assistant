# Slice 1 report: QuickyCore + `quicky`

## Result

Slice 1 and the lead-review fixes are complete. Replay now validates every complete HTTP request body, checked-in fixtures pin the system prompt by SHA-256, the persisted chat log allocates process-independent turn IDs, and the sole public `Engine` initializer synchronously restores `state.json`. The typing gesture now closes an already-open typing panel.

The requested readability pass is a separate commit from the behavior fixes. `Package.swift`, the app target, `docs/`, `make-app.sh`, and `Info.plist` were not changed. The implementation uses no `@unchecked Sendable`, `nonisolated(unsafe)`, or `@preconcurrency` escape hatch.

## Review fixes

- Removed the production-only replay header and the CLI ask preflight. `ReplayServer` reads through the HTTP header terminator, parses `Content-Length`, then reads exactly that many body bytes before decoding and matching JSON. Missing or malformed bodies fail. Unexpected additional requests fail, so any transport retry must consume its own expectation. A real URLSession-to-loopback integration test completed with one request and one consumed expectation; no retry occurred in that test.
- Replaced the fixture field exemption with `content_sha256`. Replay hashes `messages[0].content`, compares it with the fixture's pinned `Prompt.system` hash, removes that one already-validated value, and exactly matches the rest of the body.
- Moved turn-ID allocation into `ChatLog`. Its next turn number is encoded in `state.json`, and older stored states derive the next number from existing records.
- Consolidated Engine construction into `init(device:config:storeDirectory:logURL:fixedWall:deviceName:)`, whose last three arguments have defaults. It synchronously loads stored state before constructing the session. The app's three-label call remains valid, and the CLI uses the same initializer.
- Added the typing + `.typed` -> hidden transition and a reducer test.
- Reformatted `Engine.swift`, `Session.swift`, `Turn.swift`, `Chats.swift`, `main.swift`, `ReplayServer.swift`, and `Errors.swift` so statements have normal one-per-line layout.

## Verification

All output below is from the final tree after both implementation commits.

### Build

Command:

```text
swift build --disable-sandbox
```

Output:

```text
Building for debugging...
Build complete! (0.20 secs)
```

SwiftPM also printed two managed-sandbox warnings that its user-level configuration and security directories were not writable; the build completed.

### Tests

Command:

```text
swift test --disable-sandbox
```

Output:

```text
Test Suite 'QuickyCoreTests.xctest' passed at 2026-10-17 13:49:33.075.
     Executed 37 tests, with 0 failures (0 unexpected) in 0.451 (0.455) seconds
```

The new coverage uses the actual `quicky` executable and loopback server to prove a complete URLSession body is accepted, a mismatched body is rejected, a wrong system-prompt hash is rejected, and two Engines using one store emit `t1` then `t2` while the second panel scene contains both turns.

### Core import lint and removed mechanisms

Commands and results:

```text
$ scripts/lint-core-imports.sh
$ echo $?
0

$ grep -rn "Fingerprint\|fingerprint\|volatile" Sources Fixtures
$ echo $?
1
```

Both commands produced no output. The grep exit status is 1 because it found zero matches.

### Deterministic hello replay

Each of three fresh-store runs produced:

```jsonl
{"type":"session","chat":"c1","device":"fixture"}
{"type":"turn","ask":"Say hello in Hindi","chat":"c1","mode":"typed","route":"fast","turn":"t1"}
{"type":"token","text":"नम","turn":"t1"}
{"type":"token","text":"स्ते","turn":"t1"}
{"type":"done","outcome":"answered","retry":false,"total_ms":"*","ttft_ms":"*","turn":"t1"}
{"type":"quiet"}
```

All exits were 0. Both pairwise diffs were empty:

```text
0 /tmp/slice1-hello-diff12.out
0 /tmp/slice1-hello-diff13.out
```

### Deterministic cancellation replay

Each fresh-store run used `--cancel-after-ms 300`, exited 2, and ended identically:

```jsonl
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

Both pairwise diffs were empty:

```text
0 /tmp/slice1-cancel-diff12.out
0 /tmp/slice1-cancel-diff13.out
```

### Two unauthorized responses

The replay exited 1 after exactly one reload:

```jsonl
{"type":"session","chat":"c1","device":"fixture"}
{"type":"turn","ask":"hi","chat":"c1","mode":"typed","route":"fast","turn":"t1"}
{"type":"step","state":"done","text":"Reloaded the Sarvam key","turn":"t1"}
{"type":"error","message":"The Sarvam key was refused. Open Settings and check it."}
{"type":"done","outcome":"failed","retry":false,"total_ms":"*","ttft_ms":"*","turn":"t1"}
{"type":"quiet"}
```

### Wrong system-prompt hash

A temporary copy of `hello-hi` with a 64-zero `content_sha256` exited 1 and ended with the clear replay error:

```jsonl
{"type":"error","message":"request system content hash mismatch"}
```

### Live Sarvam and panel projection

`quicky ask "Say hello in Hindi"` exited 0:

```jsonl
{"type":"session","chat":"c1","device":"fixture"}
{"type":"turn","ask":"Say hello in Hindi","chat":"c1","mode":"typed","route":"fast","turn":"t1"}
{"type":"token","text":"नमस्ते","turn":"t1"}
{"type":"done","outcome":"answered","retry":false,"total_ms":259,"ttft_ms":259,"turn":"t1"}
{"type":"quiet"}
```

The same command with `--panel` also exited 0, streamed `नमस्ते`, and emitted `{"type":"panel","scene":"panel thread=1"}` after session, turn, token, done, and quiet notices.

### Live same-store history and turn IDs

Two live processes used one fresh store within five minutes. Both exited 0 and remained in `c1`:

```jsonl
{"type":"turn","ask":"Reply with exactly: first","chat":"c1","mode":"typed","route":"agent","turn":"t1"}
{"type":"done","outcome":"answered","retry":false,"total_ms":218,"ttft_ms":217,"turn":"t1"}
{"type":"quiet"}
{"type":"panel","scene":"panel thread=2"}
{"type":"turn","ask":"Reply with exactly: second","chat":"c1","mode":"typed","route":"agent","turn":"t2"}
{"type":"done","outcome":"answered","retry":false,"total_ms":206,"ttft_ms":197,"turn":"t2"}
{"type":"quiet"}
```

The second request's key-free trace contained this real history before its newest user turn:

```json
{"content":"Reply with exactly: first","role":"user"},
{"content":"first","role":"assistant"},
{"content":"OUTPUT_MODE: typed\n\nASK: Reply with exactly: second","role":"user"}
```

Its persistence trace was `persist revision=2`.

## Review commits

```text
0ae07d1 Fix slice-one replay and persisted session state
ec22229 Reformat slice-one control flow
```
