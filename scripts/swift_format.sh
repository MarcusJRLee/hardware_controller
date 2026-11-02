#!/bin/zsh

# Runs the swift-format pinned in tools/swift_format so local checks and CI lint
# identically; the Xcode-bundled formatter changes with every Xcode release.
# Usage: swift_format.sh <swift-format arguments>

set -euo pipefail

repo_root="${HC_SWIFT_FORMAT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
package="$repo_root/tools/swift_format"
# The binary is named for its pins, so a version bump can never reuse a stale build.
pin="$(cat "$package/Package.swift" "$package/Package.resolved" | shasum -a 256 | cut -c1-16)"
binary="$repo_root/.build/tools/bin/swift_format_$pin"

if [[ ! -x "$binary" ]]; then
  print -u2 "Building pinned swift-format; later runs reuse it."
  build_flags=(
    --package-path "$package"
    --scratch-path "$repo_root/.build/tools/swift_format"
    -c release
    --disable-automatic-resolution
    --disable-experimental-prebuilts
  )
  swift build "${build_flags[@]}" --product swift-format >&2
  built="$(swift build "${build_flags[@]}" --show-bin-path)/swift-format"
  mkdir -p "${binary:h}"
  cp "$built" "$binary.partial"
  mv "$binary.partial" "$binary"
fi

exec "$binary" "$@"
