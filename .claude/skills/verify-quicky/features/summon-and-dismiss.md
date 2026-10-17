# Summon and dismiss

fn+Space opens Quicky's panel at the mouse pointer over whatever app you're in. That app stays frontmost, and the panel takes your typing. Esc closes the panel, and so does fn+Space again. Keys typed while the panel is closed reach the app as usual.

## Sub-features

- `summon-typed` opens the panel in the typing state near the pointer.
- `front-app-kept` keeps the other app frontmost while the panel is up.
- `esc-close` closes the panel with Esc.
- `toggle` closes the typing panel with fn+Space. On a shown answer, fn+Space opens typing for a follow-up instead.
- `passthrough` lets ordinary keys reach the frontmost app while the panel is closed. fn+arrow and fn+F-keys never summon.
- `outside-dismiss` hides the panel on a click in another app or when another regular app activates. The panel stays up while a turn is running.

## How to get to it (user POV)

- Press and release fn+Space anywhere.
- Choose "Ask" from Quicky's menu-bar "?" menu.
- Press Esc, or fn+Space again, to close it.

## Driving it with quicky and QuickyKeys

Preconditions:

- The doctor passes. TextEdit is frontmost with an empty new document: `osascript -e 'tell application "TextEdit" to activate' -e 'tell application "TextEdit" to make new document'`.

- **Summon.** Press fn+Space. Run `keys fn+space`. The Quicky window count is 1, and the front app is still `TextEdit`.
- **Close with Esc.** Run `keys esc`. The window count is 0.
- **Toggle.** Run `keys fn+space` twice. The count goes 1, then 0.
- **Passthrough.** With the panel closed, run `keys type abc`. TextEdit's document text is `abc`: `osascript -e 'tell application "TextEdit" to text of document 1'`.
- **Engine path.** Run `printf '%s\n' '{"type":"key","key":"fn_down"}' '{"type":"key","key":"key_down","code":49}' '{"type":"key","key":"fn_up"}' | quicky --app --run sd-$(date +%s) send`. The window count is 1.
- **Close the document.** Run `osascript -e 'tell application "TextEdit" to close document 1 saving no'`.
- **Whole feature.** Run `scripts/verify-slice1.sh`. Lanes 1, 3, 5 and 6 print `PASS`.
- **Menu entry.** Not scriptable yet: the "?" menu has no stable handle for a script. A computer-use agent can click "Ask" in the menu bar. Report this entry point separately.
- **Outside dismiss.** Not scripted yet. With the panel open, a computer-use agent clicks inside TextEdit, then counts windows (expect 0).

## Gotchas

- Computer-use tools have no fn key, and they send keys to a named app, which skips Quicky's key panel. Use `keys`.
- `open -W` sometimes prints "Unable to block on application". The keys are still posted, so check the result, not that message.
- An answer that's already showing is the resting state. There, fn+Space opens typing for a follow-up rather than closing the panel.
- If the doctor's QuickyKeys check fails, the user must allow QuickyKeys in System Settings › Privacy & Security › Accessibility. You can't grant it.
- macOS "Press 🌐 key to" must be "Do Nothing", and Kivi and Wispr Flow must be quit, or fn presses get eaten before Quicky sees them.
