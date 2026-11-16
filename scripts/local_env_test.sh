#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/local_env.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
fixture="${fixture:A}"
unset HC_ENV_FILE

# Requires local_env_file, run from a directory, to print the expected path.
expect() {
  local directory="$1" expected="$2" actual
  actual="$(cd "$directory" && local_env_file)"
  [[ "$actual" == "$expected" ]] || {
    print -u2 "From $directory: expected $expected, got $actual"
    exit 1
  }
}

main="$fixture/main"
git init -q "$main"
git -C "$main" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$main" worktree add -q "$main/.worktrees/branch" -b branch

expect "$main" "$main/.env.local"
expect "$main/.worktrees/branch" "$main/.worktrees/branch/.env.local"
print 'HC_EXPECTED_TEAM_ID=TEAM' > "$main/.env.local"
expect "$main" "$main/.env.local"
expect "$main/.worktrees/branch" "$main/.env.local"
print 'HC_EXPECTED_TEAM_ID=OWN' > "$main/.worktrees/branch/.env.local"
expect "$main/.worktrees/branch" "$main/.worktrees/branch/.env.local"
mkdir "$fixture/outside"
expect "$fixture/outside" "$fixture/outside/.env.local"
HC_ENV_FILE="$fixture/override" expect "$main/.worktrees/branch" "$fixture/override"
print "local_env tests passed."
