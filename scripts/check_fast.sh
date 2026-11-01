#!/bin/zsh

# Platform-independent checks that need no Xcode, Swift, or Rust. CI runs them
# alone on Ubuntu for prose-only changes; scripts/check.sh runs them first.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

for script in scripts/*.sh; do
  zsh -n "$script"
done
scripts/classify_changes_test.sh
scripts/check_workflows_test.sh
scripts/check_workflows.sh
scripts/check_docs_test.sh
scripts/check_docs.sh
