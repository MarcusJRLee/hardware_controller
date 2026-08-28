#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

command -v rg >/dev/null || {
  print -u2 "rg is required for the iOS local-only check."
  exit 1
}

targets=(
  apps/ios/voice_input/app
  apps/ios/voice_input/config
  apps/ios/voice_input/keyboard
  apps/ios/voice_input/shared
  apps/ios/voice_input/system_capture
  apps/ios/voice_input/widgets
  apps/ios/voice_input/project.yml
)

source_pattern='\b(URLSession|URLRequest|NWConnection|NWListener|NWPathMonitor)\b|^import Network$|Network\.framework'
capability_pattern='NSAppTransportSecurity|aps-environment|com\.apple\.developer\.(associated-domains|icloud|networking)'

if rg -n --glob '*.swift' --glob '*.yml' "$source_pattern" "$targets[@]"; then
  print -u2 "iOS local-only check failed: network source or linkage found."
  exit 1
fi

if rg -n --glob '*.entitlements' --glob '*.plist' --glob '*.yml' \
  "$capability_pattern" "$targets[@]"; then
  print -u2 "iOS local-only check failed: network or cloud capability found."
  exit 1
fi

print "iOS local-only boundary: PASS"
