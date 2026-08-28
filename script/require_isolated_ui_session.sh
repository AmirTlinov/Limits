#!/usr/bin/env bash
set -euo pipefail

if [[ "${LIMITS_ISOLATED_UI_SESSION:-}" == "1" ]]; then
  exit 0
fi

cat >&2 <<'MESSAGE'
UI automation requires a dedicated macOS session because XCTest activates the
application and controls the pointer and keyboard. Run the ordinary local gate
with ./script/ci_gate.sh. The complete UI gate runs on GitHub Actions.

Maintainers may run it inside a disposable macOS runner or separate login
session with LIMITS_ISOLATED_UI_SESSION=1.
MESSAGE
exit 2
