#!/bin/sh
# Kit shim: lefthook runs scripts from .lefthook/<hook>/; the rule lives with
# the other kit hooks. stdin carries git's ref lines through exec.
exec uv run --no-project python "$(git rev-parse --show-toplevel)/.mjrlee_repo_setup/hooks/quiet_hours_rule.py" pre-push "$@"
