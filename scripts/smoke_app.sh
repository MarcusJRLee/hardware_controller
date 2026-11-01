#!/bin/zsh

# Proves a packaged app launches and stays up: the process starts from this
# exact bundle, survives the settle window, and leaves no new crash report.
# Usage: scripts/smoke_app.sh <bundle> [--demo | --installed]
#   --demo       runs the executable directly in side-effect-free demo mode.
#   --installed  opens the bundle through Launch Services and leaves it running.

set -euo pipefail

bundle="${1:?usage: smoke_app.sh <bundle> [--demo | --installed]}"
mode="${2:---demo}"
settle_seconds="${HC_SMOKE_SETTLE_SECONDS:-5}"
executable="$bundle/Contents/MacOS/HardwareController"
reports="$HOME/Library/Logs/DiagnosticReports"

smoke_fail() {
  print -u2 "Smoke failed: $1"
  exit 1
}

[[ -x "$executable" ]] || smoke_fail "$executable is not executable."
marker="$(mktemp)"
trap 'rm -f "$marker"' EXIT

case "$mode" in
  --demo)
    "$executable" --demo >/dev/null 2>&1 &
    pid=$!
    ;;
  --installed)
    open "$bundle"
    pid=""
    for _ in {1..30}; do
      pid="$(pgrep -f -x "$executable" | head -1 || true)"
      [[ -n "$pid" ]] && break
      sleep 0.5
    done
    [[ -n "$pid" ]] || smoke_fail "no process started from $executable."
    ;;
  *)
    smoke_fail "unknown mode $mode."
    ;;
esac

sleep "$settle_seconds"
kill -0 "$pid" 2>/dev/null || smoke_fail "the app exited within ${settle_seconds}s of launch."
[[ "$(ps -o args= -p "$pid")" == *"$executable"* ]] \
  || smoke_fail "pid $pid is not running from $executable."

if [[ -d "$reports" ]] \
  && [[ -n "$(find "$reports" -name 'HardwareController*' -newer "$marker" 2>/dev/null)" ]]; then
  smoke_fail "a new HardwareController crash report appeared."
fi

if [[ "$mode" == --demo ]]; then
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
fi
print "Smoke passed: $bundle ($mode, ${settle_seconds}s)."
