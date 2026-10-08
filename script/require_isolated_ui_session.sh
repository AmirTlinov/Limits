#!/usr/bin/env bash
set -euo pipefail

if [[ "${LIMITS_ISOLATED_UI_SESSION:-}" == "1" ]]; then
  exit 0
fi

cat >&2 <<'MESSAGE'
UI automation requires a dedicated macOS session because XCTest activates the
application and controls the pointer and keyboard. Run the ordinary local gate
with ./script/ci_gate.sh.

Maintainers may run it inside a separate local macOS login
session with LIMITS_ISOLATED_UI_SESSION=1.
MESSAGE
exit 2
