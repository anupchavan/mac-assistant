# Chats

Asks made within 5 minutes of the last one continue the same chat, and the model remembers the last six answered turns. Chats survive a relaunch. The footer shows the chat position ("1 of 2"). The user can step to the previous or next chat, or start a new one.

## Sub-features

- `chat-followup` keeps a follow-up in the same chat, and the model answers from the earlier turn.
- `chat-window` starts a new chat when the last ask was more than 5 minutes ago.
- `chat-persist` keeps chats and turn ids across a relaunch, and turn ids never repeat.
- `chat-nav` steps to the previous or next chat, or starts a new one.

## How to get to it (user POV)

- Ask again within 5 minutes (fn+Space, type, Return).
- Planned: ⌘[ and ⌘] for the previous and next chat, and ⌘N for a new chat. **The panel does not handle these keys yet.** Only the engine command reaches them.

## Driving it with quicky and QuickyKeys

Preconditions:

- `swift build --product quicky` has run. A fresh store: `S=$(mktemp -d)`.

- **Follow-up memory (CLI, live).** Run `quicky ask "Reply with exactly: first" --store $S`, then `quicky ask "What did I ask you to reply before?" --store $S --trace`. Both `turn` lines show the same `chat`, the turn ids are `t1` then `t2`, and the second answer mentions "first". The trace's request body holds the first turn as history.
- **Persistence (real app).** Run `quicky --app --run chat-$(date +%s)-a ask "Reply with exactly: alpha"`, then `./make-app.sh verify run`, then `quicky --app --run chat-$(date +%s)-b ask "What did I just ask?"`. The two `turn` notices share a `chat`, and the second answer refers to "alpha".
- **Physical follow-up.** Run lane 4 of `scripts/verify-slice1.sh`. It prints `PASS 4 follow-up continues the same chat`.
- **Navigation (engine only).** Run `printf '%s\n' '{"type":"command","command":"new_chat"}' | quicky --app --run nav-$(date +%s) send`. A `session` notice with a new `chat` id appears. Run `{"type":"command","command":"previous_chat"}` and the earlier id comes back. The commands are `ignored` unless the panel is resting on an answer.
- **Continue window.** Covered by the core unit tests (`ChatLog` continue window). A live check needs a 5-minute wait, so run it only when the window rule changed. Ask, wait 301 s, ask again, and the `chat` id changes.

## Gotchas

- The keyboard entry points (⌘[, ⌘], ⌘N) are not built. Report `chat-nav` through the keyboard as unreachable, not as verified through the engine command.
- The verify build's chats live in `…/dev.anup.assistant/verify/state.json`, and the user's real chats live one level up. Never read or reset the real one.
- A CLI run without `--store` uses a fresh temporary store, so it never continues a chat.
