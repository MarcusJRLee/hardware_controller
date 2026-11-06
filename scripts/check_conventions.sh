#!/bin/zsh

# Enforces repository rules mechanically so they never depend on a reader
# remembering them: path naming, colocated tests, a framework-free domain,
# confined network APIs, and the pinned formatter.

set -euo pipefail

repo_root="${HC_CONVENTIONS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$repo_root"

failures=()
tracked=("${(@f)$(git ls-files)}")

# Dashes are reserved for ecosystem-mandated names.
for file in "${tracked[@]}"; do
  [[ "$file" == .github/* || "$file" == *.xcodeproj/* || "$file" == (rust-toolchain.toml|.swift-format) ]] && continue
  [[ "$file" == *-* ]] && failures+=("$file: use lowercase_with_underscores, not dashes")
done

# Every Swift source has `<name>_test(s).swift` or a reasoned exemption.
manifest="Tests/untested_sources.txt"
typeset -A exempt
for line in "${(@f)$(grep -vE '^(#|$)' "$manifest" || true)}"; do
  source_path="${line%% | *}"
  reason="${line#* | }"
  exempt[$source_path]="$reason"
  [[ -e "$source_path" ]] || failures+=("$manifest: $source_path no longer exists")
  for name in "${(@f)$(print -r -- "$reason" | grep -oE '`[^`]+`' | tr -d '`' || true)}"; do
    if [[ -z "$name" ]]; then
      continue
    elif [[ "$name" == */* ]]; then
      [[ -e "$name" ]] || failures+=("$manifest: $source_path cites missing $name")
    elif [[ " ${tracked[*]} " != *"/${name}.swift "* ]]; then
      failures+=("$manifest: $source_path cites missing test $name")
    fi
  done
done
test_files=(${(M)tracked:#*_test(|s).swift})
test_stems=(${test_files:t:r})
test_names=" ${test_stems[*]} "
for source_path in "${(@M)tracked:#(Sources|apps)/*.swift}"; do
  [[ "$source_path" == *_test(|s).swift || "$source_path" == */tests/* || "$source_path" == */ui_tests/* ]] && continue
  name="${source_path:t:r}"
  has_test=0
  [[ "$test_names" == *" ${name}_test "* || "$test_names" == *" ${name}_tests "* ]] && has_test=1
  if (( has_test )) && [[ -n "${exempt[$source_path]:-}" ]]; then
    failures+=("$manifest: $source_path now has a test; remove its exemption")
  elif (( ! has_test )) && [[ -z "${exempt[$source_path]:-}" ]]; then
    failures+=("$source_path: add ${name}_test.swift or a reasoned entry in $manifest")
  fi
done

# The domain imports nothing but Foundation.
for import_line in "${(@f)$(git grep -hE '^(@testable )?import ' -- 'Sources/HardwareControllerCore/*.swift' | sort -u || true)}"; do
  [[ "$import_line" == "import Foundation" ]] || failures+=("HardwareControllerCore: forbidden ${import_line}")
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
