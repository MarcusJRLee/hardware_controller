#!/bin/zsh

# Resolves the ignored private configuration (signing identities, Team IDs).
# Linked worktrees, where the repo kit puts every branch, have no .env.local of
# their own, so they read the main checkout's. HC_ENV_FILE overrides both.
# Source this file, then call local_env_file; the printed path may not exist,
# so callers decide whether a missing file is an error.

local_env_file() {
  if [[ -n "${HC_ENV_FILE:-}" ]]; then
    print -r -- "$HC_ENV_FILE"
    return
  fi
  local checkout common
  checkout="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    print -r -- "$PWD/.env.local"
    return
  }
  if [[ ! -f "$checkout/.env.local" ]]; then
    # The common directory is the main checkout's .git in every linked worktree.
    common="$(git rev-parse --path-format=absolute --git-common-dir)"
    if [[ "${common:t}" == ".git" && -f "${common:h}/.env.local" ]]; then
      print -r -- "${common:h}/.env.local"
      return
    fi
  fi
  print -r -- "$checkout/.env.local"
}
