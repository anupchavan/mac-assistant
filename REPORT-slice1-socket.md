# Slice 1 socket report

## Result

Implemented the authenticated `QUICKY_VERIFY` Unix-domain socket and `quicky --app` client.

- The verifier listens at `~/Library/Application Support/dev.anup.assistant/quicky.sock`, removes a stale socket before binding, and applies mode `0600`.
- Each launch writes a fresh random token to `verify-token` with mode `0600`. A client that does not send a valid `hello` first is disconnected.
- Socket reads, writes, accept, connect, token-file access, and listener setup run off the main actor. `Engine.send` still performs no I/O.
- Inputs are decoded by the existing JSONL codec and sent to `Engine` on the main actor. A client receives only notices carrying a run it sent; runless and other-run notices are filtered. The run is removed from the client's routing set after `quiet`.
- `onNotice` was not replaced. Under `QUICKY_VERIFY`, `Engine` has a small additive observer list. `publish` continues to call `onNotice` and append to `NoticeLog`, then fans the same notice to verifier observers. This is smaller and safer than wrapping a mutable callback that another owner could later replace.
- `quicky --app --run ID [--timeout-ms N] ask TEXT` and `send` read the token, authenticate, attach the requested run to every input, print only that run, map the `done` outcome to the documented exit code, and exit at `quiet`. Overall timeout exits 3. A key-input batch exits on its next notice or after at most 500 ms of silence.
- `QuickyApp` starts the server only inside `#if QUICKY_VERIFY`.

Commits:

```text
078a5bc Add authenticated verify socket server
f0854ab Add app-backed quicky CLI mode
```

## Verification output

This managed environment requires `--disable-sandbox` and writable compiler caches because nested SwiftPM sandbox setup is denied. Those switches do not change source configuration.

### Debug build

```text
$ swift build --disable-sandbox
[46/48] QuickyApp-product
Build complete! (1.99 secs)
swift build exit=0
```

### Verify build

```text
$ swift build --disable-sandbox -Xswiftc -DQUICKY_VERIFY
[42/42] quicky-product
Build complete! (2.53 secs)
verify build exit=0
```

The existing `kSecUseAuthenticationUIFail` deprecation warning is still emitted; there are no new build warnings from the socket or CLI code.

### Tests

```text
$ swift test --disable-sandbox
Test Suite 'QuickyCoreTests.xctest' passed
    Executed 38 tests, with 4 tests skipped and 0 failures
Test Suite 'QuickyAppTests.xctest' passed
    Executed 8 tests, with 0 failures
swift test exit=0
```

The four skips are existing replay tests whose Network listeners receive `EPERM` in this outer sandbox. They now skip only when output contains the exact listener-permission failure, rather than accidentally passing for the wrong reason. They remain active elsewhere.

The always-run pure protocol test passed and covers invalid-token rejection, `ask` decoding/encoding with a run, exclusion of runless and other-run notices, and delivery through the owned run's final `quiet`.

There is also a verify-flag integration test with a stubbed chat transport and a temporary Unix socket. It covers bad-token disconnect plus an owned `ask` producing `token`, `done`, and final `quiet`. In this environment:

```text
$ swift test --disable-sandbox -Xswiftc -DQUICKY_VERIFY --filter VerifySocketTests
Test skipped - The test sandbox forbids binding Unix-domain sockets
Executed 1 test, with 1 test skipped and 0 failures
```

This is the brief's allowed pure-routing fallback for an XCTest environment that cannot bind a socket.

### Core import lint

```text
$ scripts/lint-core-imports.sh
lint exit=0
```

### Release exclusion

The release app was built without `QUICKY_VERIFY`, with debug-info generation disabled only to avoid the managed environment's `dsymutil` denial:

```text
$ swift build --disable-sandbox -c release -debug-info-format none --product QuickyApp
Build complete! (5.13 secs)

$ strings .build/out/Products/Release/QuickyApp | grep 'quicky\.sock'

$ nm .build/out/Products/Release/QuickyApp | grep -Ei 'VerifySocket|serve.*socket'

```

Both greps produced empty output. As a positive control, the verify-built debug app does contain the marker:

```text
$ strings .build/out/Products/Debug/QuickyApp | grep 'quicky\.sock'
Library/Application Support/dev.anup.assistant/quicky.sock
```

## Lead-run end-to-end proof

I did not launch `Quicky.app`, as required. From the repository root, the lead should run the following with a working configured Sarvam key:

```bash
swift build --product quicky
./make-app.sh verify run

support="$HOME/Library/Application Support/dev.anup.assistant"
until [[ -S "$support/quicky.sock" && -f "$support/verify-token" ]]; do sleep 0.1; done
stat -f '%Lp %N' "$support/quicky.sock" "$support/verify-token"

log="$HOME/Library/Logs/Quicky/quicky.log"
touch "$log"
offset=$(wc -c < "$log" | tr -d ' ')
run="slice1-$(date +%s)"
.build/debug/quicky --app --run "$run" --timeout-ms 20000 ask "Say hello in Hindi"
status=$?
echo "exit=$status run=$run"

sleep 2
tail -c +$((offset + 1)) "$log" | grep '"run":"'"$run"'"'
```

Expected proof:

- `stat` prints `600` for both the socket and token.
- CLI output contains only the chosen run, includes `turn`, any `token` lines, `done` with outcome `answered`, and ends with `quiet`.
- The CLI exit is `0`.
- The app log suffix contains the same ordered notices for that run. After the two-second wait, no notice for that run follows `quiet`.

To exercise the key-line silence behavior separately:

```bash
run="slice1-key-$(date +%s)"
printf '%s\n' \
  '{"type":"key","key":"fn_down"}' \
  '{"type":"key","key":"key_down","code":49}' \
  '{"type":"key","key":"fn_up"}' \
  | .build/debug/quicky --app --run "$run" send
echo "exit=$? run=$run"
```

This command must return after the next run-matched notice or no more than 500 ms of silence.
