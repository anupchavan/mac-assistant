#!/bin/bash
# Read-only: is the running Quicky a verify build from this checkout, reachable and drivable?
set -uo pipefail
cd "$(dirname "$0")/.."
support="$HOME/Library/Application Support/dev.anup.assistant"
bad=0
check() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; bad=1; fi; }

check "verify Quicky.app from this checkout is running" "pgrep -f '$PWD/build/verify/Quicky.app/Contents/MacOS/Quicky'"
check "only one Quicky process" "[[ \$(pgrep -x Quicky | wc -l) -eq 1 ]]"
check "verify socket and token exist, mode 600" "[[ -S '$support/quicky.sock' && \$(stat -f %Lp '$support/quicky.sock') == 600 && \$(stat -f %Lp '$support/verify-token') == 600 ]]"
check "quicky CLI is built" "[[ -x .build/debug/quicky ]]"
out=$(mktemp); open -n -W -g --stdout "$out" --stderr "$out" build/verify/QuickyKeys.app --args check
check "QuickyKeys may post events (Accessibility)" "grep -q 'post-events: ok' '$out'"
check "engine answers over the socket (an empty ask comes back ignored)" ".build/debug/quicky --app --run doctor-\$\$ --timeout-ms 3000 ask ''; [[ \$? == 4 ]]"
exit $bad
