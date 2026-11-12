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
scripts/swift_format_test.sh
scripts/check_workflows_test.sh
scripts/check_workflows.sh
scripts/ci_durations_test.sh
scripts/check_conventions_test.sh
scripts/check_conventions.sh
scripts/check_docs_test.sh
scripts/check_docs.sh
# Repo-kit gates; its agent hooks only warn about newly written files.
uv run --no-project python .mjrlee_repo_setup/hooks/markdown_placement.py
uv run --no-project python .mjrlee_repo_setup/hooks/docker_labels.py
uv run --no-project python .mjrlee_repo_setup/tools/roadmap.py check
uv run --no-project python .mjrlee_repo_setup/hooks/test_ownership.py
uv run --no-project python .mjrlee_repo_setup/hooks/repo_config.py
