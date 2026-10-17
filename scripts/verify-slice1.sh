#!/bin/bash
# Slice 1 on the real app, through the physical event-tap path. Needs `./make-app.sh verify run`
# and QuickyKeys.app allowed to post events (Accessibility). Prints one PASS/FAIL line per lane.
set -uo pipefail
cd "$(dirname "$0")/.."

KEYS=build/verify/QuickyKeys.app
LOG="$HOME/Library/Logs/Quicky/verify.log"
fails=0

keys() { open -n -W -g "$KEYS" --args "$@"; sleep 0.3; }
panels() {
  swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
print(l.filter { ($0["kCGWindowOwnerName"] as? String) == "Quicky" }.count)' 2>/dev/null | tail -1
}
front() { osascript -e 'tell application "System Events" to name of first process whose frontmost is true'; }
doc() { osascript -e 'tell application "TextEdit" to text of document 1'; }
lane() { if [[ "$2" == ok ]]; then echo "PASS $1"; else echo "FAIL $1: $3"; fails=$((fails + 1)); fi; }
since() { tail -c +$((offset + 1)) "$LOG"; }

osascript -e 'tell application "TextEdit" to activate' -e 'tell application "TextEdit" to make new document' >/dev/null
sleep 1
touch "$LOG"
offset=$(wc -c < "$LOG" | tr -d ' ')

[[ $(panels) == 0 ]] || keys esc
keys fn+space
sleep 0.5
[[ $(panels) -ge 1 && $(front) == TextEdit ]] && lane "1 fn+Space summons over TextEdit, which stays frontmost" ok \
  || lane "1 summon" no "panels=$(panels) front=$(front)"

keys type "Say hello in Hindi"
keys return
for _ in $(seq 1 50); do since | grep -q '"type":"done"' && break; sleep 0.2; done
answered=$(since | grep -c '"outcome":"answered"')
[[ $answered -ge 1 && -z $(doc) && $(front) == TextEdit ]] && lane "2 typed ask streams an answer; nothing typed into TextEdit" ok \
  || lane "2 ask" no "answered=$answered doc='$(doc)' front=$(front)"

keys esc
sleep 0.3
[[ $(panels) == 0 ]] && lane "3 Esc closes the panel" ok || lane "3 esc" no "panels=$(panels)"

offset=$(wc -c < "$LOG" | tr -d ' ')
keys fn+space
keys type "What did I just ask you to do?"
keys return
for _ in $(seq 1 50); do since | grep -q '"type":"done"' && break; sleep 0.2; done
chat_first=$(tail -c +1 "$LOG" | grep '"ask":"Say hello in Hindi"' | tail -1 | sed -E 's/.*"chat":"([^"]+)".*/\1/')
chat_second=$(since | grep '"type":"turn"' | tail -1 | sed -E 's/.*"chat":"([^"]+)".*/\1/')
[[ -n $chat_first && $chat_first == "$chat_second" ]] && lane "4 follow-up continues the same chat ($chat_second)" ok \
  || lane "4 follow-up" no "first=$chat_first second=$chat_second"

keys fn+space
sleep 0.3
open_for_followup=$(panels)
keys fn+space
sleep 0.3
[[ $open_for_followup -ge 1 && $(panels) == 0 ]] && lane "5 fn+Space on an answer opens typing; again closes it" ok \
  || lane "5 toggle" no "after first=$open_for_followup after second=$(panels)"

keys type "abc"
[[ $(doc) == abc ]] && lane "6 ordinary typing reaches TextEdit" ok || lane "6 passthrough" no "doc='$(doc)'"

osascript -e 'tell application "TextEdit" to close document 1 saving no' >/dev/null
exit $fails
