#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

command -v xcodegen >/dev/null || {
  print -u2 "xcodegen is required to generate the iOS probe project."
  exit 1
}

xcodegen generate \
  --spec apps/ios_probe/project.yml \
  --project apps/ios_probe
