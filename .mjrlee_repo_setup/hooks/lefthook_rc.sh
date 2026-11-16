# shellcheck shell=sh
# Kit rc file: the kit's lefthook.yml names it as `rc`, so every git hook
# lefthook installs sources it, from the worktree root, before running lefthook.
# Sourcing makes it the one point that sees the whole pre-push hook, every
# repo's gate included, and lefthook's exit code (through the EXIT trap).
# It only reports (gate_report.py): it never changes that exit code, and does
# nothing without uv. Names share the hook's shell, hence the prefix.
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
