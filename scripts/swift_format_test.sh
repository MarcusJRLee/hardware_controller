#!/bin/zsh

set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/swift_format.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/tools/swift_format" "$root/stub"
print "manifest" > "$root/tools/swift_format/Package.swift"
print "pins a" > "$root/tools/swift_format/Package.resolved"

# A stub toolchain records each build and produces a formatter that echoes.
cat > "$root/stub/swift" <<'STUB'
#!/bin/zsh
bin="$HC_STUB_ROOT/built"
if [[ " $* " == *" --show-bin-path "* ]]; then print "$bin"; exit 0; fi
print build >> "$HC_STUB_ROOT/builds.log"
mkdir -p "$bin"
print '#!/bin/zsh\nprint "formatted $*"' > "$bin/swift-format"
chmod +x "$bin/swift-format"
STUB
chmod +x "$root/stub/swift"

run() {
  HC_SWIFT_FORMAT_ROOT="$root" HC_STUB_ROOT="$root" PATH="$root/stub:$PATH" \
    "$script" "$@" 2>/dev/null
}
builds() { wc -l < "$root/builds.log" | tr -d ' '; }
fail() { print -u2 "$1"; exit 1; }

[[ "$(run lint x.swift)" == "formatted lint x.swift" ]] || fail "Arguments must reach the formatter."
[[ "$(builds)" == 1 ]] || fail "The first run must build once."
run lint >/dev/null
[[ "$(builds)" == 1 ]] || fail "A built pin must be reused."
print "pins b" > "$root/tools/swift_format/Package.resolved"
run lint >/dev/null
[[ "$(builds)" == 2 ]] || fail "A changed pin must rebuild."
print "swift_format tests passed."
