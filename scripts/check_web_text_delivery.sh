#!/bin/zsh

# Proves first-attempt Dictation delivery into a Chromium web field
# (docs/decisions/macos_text_delivery.md). A throwaway browser profile starts
# with its accessibility tree off, which is the state that made the first
# pedal press after a quiet period fail on Gemini. The app's
# --verify-focused-text-delivery diagnostic then captures and fills the field
# once. Needs a signed app with Accessibility granted, so it runs on installs,
# not in CI. Without a Chromium browser it does nothing.
# Usage: scripts/check_web_text_delivery.sh [APP]
#   HC_WEB_CHECK_BROWSER  a Chromium-based .app to use instead of the first found.

set -euo pipefail
zmodload zsh/datetime

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-/Applications/Hardware Controller.app}"
fixture="$repo_root/scripts/fixtures/web_text_delivery.html"

check_fail() {
  print -u2 "Web text delivery failed: $1"
  exit 1
}

browser="${HC_WEB_CHECK_BROWSER:-}"
if [[ -z "$browser" ]]; then
  for candidate in "Brave Browser" "Google Chrome" "Chromium" "Microsoft Edge"; do
    if [[ -d "/Applications/$candidate.app" ]]; then
      browser="/Applications/$candidate.app"
      break
    fi
  done
fi
if [[ -z "$browser" ]]; then
  print "Web text delivery skipped: no Chromium-based browser in /Applications."
  exit 0
fi
[[ -d "$app" ]] || check_fail "$app does not exist."

profile="$(mktemp -d)"
output="$(mktemp)"
browser_pid=""
cleanup() {
  [[ -n "$browser_pid" ]] && kill -TERM "$browser_pid" 2>/dev/null || true
  for _ in {1..50}; do
    [[ -n "$browser_pid" ]] && kill -0 "$browser_pid" 2>/dev/null || break
    sleep 0.1
  done
  [[ -n "$browser_pid" ]] && kill -KILL "$browser_pid" 2>/dev/null || true
  rm -rf "$profile" "$output"
}
trap cleanup EXIT

# The browser must be a separate instance, so the user's own windows and
# profile are never touched.
open -n -a "$browser" --args \
  --user-data-dir="$profile" \
  --no-first-run \
  --no-default-browser-check \
  --disable-extensions \
  --remote-debugging-port=0 \
  "file://$fixture"

# Readiness comes from DevTools, never Accessibility, so the diagnostic's
# capture is the first accessibility client the page sees.
ready=""
for _ in {1..150}; do
  [[ -n "$browser_pid" ]] \
    || browser_pid="$(pgrep -f -- "--user-data-dir=$profile" | head -1 || true)"
  if [[ -n "$browser_pid" && -f "$profile/DevToolsActivePort" ]]; then
    port="$(head -1 "$profile/DevToolsActivePort")"
    if curl -sf --max-time 1 "http://127.0.0.1:$port/json/list" | grep -q '"title": *"ready"'; then
      ready=1
      break
    fi
  fi
  sleep 0.1
done
[[ -n "$ready" ]] || check_fail "the fixture never finished loading."

# Launching the diagnostic can take keyboard focus, and LaunchServices may
# front the user's own instance of the same browser, so keep activating this
# instance by pid (AppKit, no Accessibility) until the diagnostic exits. The
# diagnostic waits for this window before it captures.
activate_browser() {
  osascript -l JavaScript -e 'ObjC.import("AppKit")' -e \
    "\$.NSRunningApplication.runningApplicationWithProcessIdentifier($browser_pid).activateWithOptions(1)" \
    >/dev/null
}
marker="hc-web-check-$RANDOM$RANDOM"
start=$EPOCHREALTIME
open -n -g -W --stdout "$output" --stderr "$output" "$app" \
  --args --verify-focused-text-delivery "$browser_pid" "$marker" &
diagnostic=$!
while kill -0 "$diagnostic" 2>/dev/null; do
  activate_browser
  sleep 0.2
done
wait "$diagnostic" || true
elapsed_ms=$(( (EPOCHREALTIME - start) * 1000 ))
grep -v '^Unable to block' "$output" || true
grep -q '^FAIL' "$output" && check_fail "see the lines above."
grep -q '^PASS delivered' "$output" || check_fail "the diagnostic reported no delivery."
printf 'Web text delivery passed: %s in %.0f ms.\n' "${browser:t:r}" "$elapsed_ms"
