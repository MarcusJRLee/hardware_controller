#!/bin/zsh

set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/smoke_app.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# Builds a bundle whose executable runs the given shell body.
make_bundle() {
  local bundle="$fixture/$1.app"
  mkdir -p "$bundle/Contents/MacOS"
  print -r -- "#!/bin/zsh
$2" > "$bundle/Contents/MacOS/HardwareController"
  chmod +x "$bundle/Contents/MacOS/HardwareController"
  print -r -- "$bundle"
}

export HC_SMOKE_SETTLE_SECONDS=1
"$script" "$(make_bundle stays 'sleep 30')" --demo >/dev/null
if "$script" "$(make_bundle exits 'exit 0')" --demo >/dev/null 2>&1; then
  print -u2 "Expected failure: an app that exits during the settle window."
  exit 1
fi
if "$script" "$fixture/missing.app" --demo >/dev/null 2>&1; then
  print -u2 "Expected failure: a bundle without an executable."
  exit 1
fi
print "smoke_app tests passed."
