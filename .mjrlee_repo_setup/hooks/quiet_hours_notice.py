"""UserPromptSubmit hook: tell the agent when quiet hours are on.

Inside a window (`quiet_hours.py`), `guard_git.py` and the git hooks deny every
commit, push, and GitHub write. Saying so up front lets the agent plan local
work instead of hitting denials. Outside a window, or with no quiet hours or a
malformed `repo.toml`, it prints nothing, so it costs no context.
"""

from __future__ import annotations

import sys
from datetime import UTC, datetime

from hook_event import context_output, parse_prompt_event
from quiet_hours_rule import hours_at
from repo_config import CONFIG, RepoConfigError


def notice(hours_until: str) -> str:
    return (
        f"Quiet hours are on until {hours_until} ({CONFIG}). Edit and test"
        " locally, but make no commits, pushes, or GitHub writes until then;"
        " hooks deny them."
    )


def main() -> int:
    event = parse_prompt_event(sys.stdin.read())
    try:
        hours = hours_at(event.cwd)
    except RepoConfigError:
        return 0
    now = datetime.now(UTC)
    until = hours.quiet_until(now) if hours else None
    if hours and until:
        print(context_output(event, notice(hours.describe(until))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
