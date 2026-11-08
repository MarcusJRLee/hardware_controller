#!/bin/sh
# Kit shim: lefthook runs scripts from .lefthook/<hook>/; the setup lives with
# the other kit hooks.
exec uv run --no-project python "$(git rev-parse --show-toplevel)/.mjrlee_repo_setup/hooks/setup_checkout.py" "$@"
