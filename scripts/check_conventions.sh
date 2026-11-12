#!/bin/zsh

# Enforces repository rules mechanically so they never depend on a reader
# remembering them: path naming, a framework-free domain, a portable Rust
# core, confined network APIs, and the pinned formatter.

set -euo pipefail

repo_root="${HC_CONVENTIONS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$repo_root"

# Unique, so a line matching several rules is reported once.
typeset -U failures
failures=()
tracked=("${(@f)$(git ls-files)}")

# Dashes are reserved for ecosystem-mandated names. Lefthook runs scripts only
# from `.lefthook/<git hook name>/`, so only that directory may be dashed.
for file in "${tracked[@]}"; do
  [[ "$file" == .github/* || "$file" == *.xcodeproj/* || "$file" == (rust-toolchain.toml|.swift-format) ]] && continue
  [[ "$file" == .lefthook/*/* ]] && file="${file#.lefthook/*/}"
  [[ "$file" == *-* ]] && failures+=("$file: use lowercase_with_underscores, not dashes")
done

# The domain imports nothing but Foundation.
for import_line in "${(@f)$(git grep -hE '^(@testable )?import ' -- 'Sources/HardwareControllerCore/*.swift' | sort -u || true)}"; do
  [[ "$import_line" == "import Foundation" ]] || failures+=("HardwareControllerCore: forbidden ${import_line}")
done

# The Rust core and its C header stay portable (docs/decisions/
# portable_voice_engine.md): the header includes only standard C headers, and
# no crate names an Apple framework, type, target, link kind, path, or binding
# crate. Apple specifics belong on the Swift side of the boundary.
for include_line in "${(@f)$(git grep -hE '^[[:space:]]*#[[:space:]]*(include|import)' -- 'crates/*.h' | sort -u || true)}"; do
  [[ -z "$include_line" || "$include_line" == "#include <"(stddef|stdint)".h>" ]] && continue
  failures+=("crates C header: only <stddef.h> and <stdint.h> may be included, not ${include_line}")
done
edge='(^|[^A-Za-z0-9_])'
apple_patterns=(
  "${edge}(Core(Foundation|Audio|Graphics|Media|ML|Text|Video)|AudioToolbox|AVFoundation|AppKit|UIKit|IOKit|Foundation|Darwin|objc2?)([^A-Za-z0-9_]|\$)"
  "${edge}(NS|CF|CG|CM|CV|AV|UI|MTL|Sec)[A-Z][a-z]"
  '__APPLE__|TARGET_OS_|target_vendor *= *"apple"|target_os *= *"(macos|ios|tvos|watchos|visionos)"'
  'kind *= *"framework"|=framework=|-framework'
  'Library/|/Applications|Application Support|\.xcframework|\.app/'
  '^name = "(core-(foundation|graphics|text|audio)[a-z-]*|coreaudio[a-z-]*|cocoa[a-z-]*|objc[a-z0-9-]*|block2?|block-sys|dispatch2?|security-framework[a-z-]*|system-configuration[a-z-]*|metal|io-kit[a-z-]*|mach2?|fsevent[a-z-]*|apple-[a-z-]*)"$'
)
for pattern in "${apple_patterns[@]}"; do
  for match in "${(@f)$(git grep -nE "$pattern" -- crates Cargo.toml Cargo.lock || true)}"; do
    [[ -n "$match" ]] && failures+=("$match: Apple specifics stay on the Swift side of the Rust boundary")
  done
done

# Only the fixed-loopback Ollama adapter and the pinned speech-model fetcher
# (docs/decisions/asr_runtime.md, model_packages.md) may use a network API.
network_files=(
  Sources/HardwareControllerMac/ollama_local_ai_refiner.swift
  Sources/hardware_controller_model_download/asr_model_file_fetcher.swift
)
for file in "${(@f)$(git grep -lwE '(URLSession|NWConnection|NWListener|CFStream)' -- 'Sources/*.swift' || true)}"; do
  [[ -z "$file" || ${network_files[(Ie)$file]} -gt 0 ]] && continue
  failures+=("$file: network APIs are confined to the Ollama adapter and model fetcher")
done

# Only the Gemini panel (docs/decisions/local_only_boundary.md) may host web
# content; it loads an allow-listed set of Google hosts.
webkit_files=(
  Sources/HardwareControllerMac/ask_gemini_chat.swift
  Sources/HardwareControllerMac/ask_gemini_panel.swift
)
for file in "${(@f)$(git grep -lwE '(import WebKit|WKWebView)' -- 'Sources/*.swift' || true)}"; do
  [[ -z "$file" || ${webkit_files[(Ie)$file]} -gt 0 ]] && continue
  failures+=("$file: web content is confined to the Gemini panel")
done

# Xcode's bundled formatter differs per Xcode release; only the pinned one lints.
for file in "${(@f)$(git grep -lE '^[[:space:]]*(- )?(run: )?swift format ' -- 'scripts/*.sh' '.github/*' || true)}"; do
  [[ -z "$file" ]] && continue
  failures+=("$file: run scripts/swift_format.sh, not the Xcode-bundled swift format")
done

if (( ${#failures} )); then
  print -u2 -l "${failures[@]}"
  exit 1
fi
print "Repository conventions hold."
