# shellcheck shell=sh
# Kit rc file: the kit's lefthook.yml names it as `rc`, so every git hook
# lefthook installs sources it, from the worktree root, before running lefthook.
# Sourcing makes it the one point that sees the whole hook, every repo's gate
# included, and lefthook's exit code (through the EXIT trap). It does two
# things: it hides git's repo-local variables from the hook, and on pre-push it
# reports (gate_report.py) without ever changing the exit code. Names share the
# hook's shell, hence the prefix.

# Prints where git finds this repo; fails outside a work tree.
mjrlee_repo_layout() {
  git rev-parse --path-format=absolute --git-dir --git-common-dir \
    --show-toplevel --git-path objects 2>/dev/null
}

mjrlee_index_path() {
  git rev-parse --path-format=absolute --git-path index 2>/dev/null
}

# Git exports GIT_DIR, GIT_INDEX_FILE, and their kin to hooks, as absolute paths
# in a linked worktree, and they outrank discovery: a gate's test that runs git
# in a scratch repo would act on this one. From the worktree root, discovery
# finds the same repo, so this unsets each variable whose removal leaves the
# repo's layout unchanged; any other layout keeps them all. `-c` config stays,
# as git keeps it for submodules. A partial commit's temporary GIT_INDEX_FILE
# stays too: lefthook reads the staged files from it.
mjrlee_hide_repo_env() {
  mjrlee_vars=$(git rev-parse --local-env-vars 2>/dev/null |
    grep -vx -e GIT_CONFIG_PARAMETERS -e GIT_CONFIG_COUNT) || return 0
  mjrlee_layout=$(mjrlee_repo_layout) || return 0
  mjrlee_index=$(mjrlee_index_path)
  # shellcheck disable=SC2086 # Git prints one name per line.
  [ "$(
    unset $mjrlee_vars
    mjrlee_repo_layout
  )" = "$mjrlee_layout" ] || return 0
  # shellcheck disable=SC2086 # Git prints one name per line.
  if [ "$(
    unset $mjrlee_vars
    mjrlee_index_path
  )" != "$mjrlee_index" ]; then
    mjrlee_vars=$(printf '%s\n' "$mjrlee_vars" | grep -vx GIT_INDEX_FILE)
  fi
  # shellcheck disable=SC2086 # Git prints one name per line.
  unset $mjrlee_vars
}

mjrlee_hide_repo_env

mjrlee_gate_report() {
  uv run --no-project python .mjrlee_repo_setup/hooks/gate_report.py "$@" </dev/null
}

# Runs as the hook exits; `$?` is still lefthook's exit code on entry.
mjrlee_gate_finish() {
  mjrlee_gate_status=$?
  mjrlee_gate_report finish "$mjrlee_gate_status" "$mjrlee_gate_state" || :
  exit "$mjrlee_gate_status"
}

case "$0" in
  */pre-push)
    if command -v uv >/dev/null 2>&1; then
      # Redirected stdin keeps git's ref lines for lefthook.
      mjrlee_gate_state=$(mjrlee_gate_report start) || mjrlee_gate_state=
      trap mjrlee_gate_finish EXIT
    fi
    ;;
esac
