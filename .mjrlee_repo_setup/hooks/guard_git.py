"""PreToolUse hook: block agent shell commands that bypass the kit's git hooks.

The [Git] rules run as git hooks (`push_rules.py`, `worktree_rules.py`), where
git supplies the real refs and paths, so no shell parsing is needed there. This
hook only denies the few ways to switch those hooks off, by plain text match.
Blocks by printing an explicit JSON deny decision, which Claude Code and Codex
both honor.
"""

from __future__ import annotations

import re
import sys
from typing import Final

from hook_event import deny_output, parse_event

# (pattern, what it does). Matching is textual, so a commit message or PR body
# that merely mentions one is caught too; BYPASS_HINT says how to pass it.
BYPASSES: Final = (
    (
        re.compile(r"\bgit\b[^\n;&|]*\s--no-verify\b"),
        "`--no-verify` skips git hooks",
    ),
    (
        re.compile(r"core\.hooksPath", re.IGNORECASE),
        "a `core.hooksPath` override skips git hooks",
    ),
    (
        re.compile(r"\bLEFTHOOK=(?:0|false|off)\b", re.IGNORECASE),
        "`LEFTHOOK=0` disables lefthook",
    ),
    (
        re.compile(r"\bLEFTHOOK_(?:EXCLUDE|SKIP)\b"),
        "`LEFTHOOK_EXCLUDE` skips lefthook jobs",
    ),
    (
        re.compile(r"\blefthook\s+uninstall\b"),
        "`lefthook uninstall` removes the git hooks",
    ),
    (
        re.compile(r"\bworktree\s+add\b[^\n;&|]*--no-checkout\b"),
        "`--no-checkout` skips the worktree location check",
    ),
)
BYPASS_HINT: Final = (
    "The kit's git hooks enforce the [Git] rules in AGENTS.md. If the user "
    "explicitly wants this, ask them to run it themselves; if this is only "
    "text, pass it from a file (`git commit -F`, `gh pr create --body-file`)."
)


def find_bypass(command: str) -> str | None:
    """Return what the first hook bypass in `command` does, or None."""

    return next(
        (why for pattern, why in BYPASSES if pattern.search(command)), None
    )


def main() -> int:
    event = parse_event(sys.stdin.read())
    why = find_bypass(event.command or "")
    if why is not None:
        print(deny_output(event, f"Blocked: {why}. {BYPASS_HINT}"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
