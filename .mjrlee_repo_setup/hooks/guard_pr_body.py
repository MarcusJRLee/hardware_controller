"""PreToolUse hook: deny agent PR bodies that weigh no alternatives.

AGENTS.md requires every PR description to carry a decision matrix of the
alternatives considered, or a `No alternatives: <why>` line, so a reviewer can
see why the design won. This hook checks `gh pr create` and `gh pr edit` when
they set a body. The body is searched in the command text, which holds `--body`
values and heredocs, plus any `--body-file`; a body built from a variable is
denied, and the reason says to pass a file. `gh pr create --web` passes, since
a person writes that body in the browser, as does a `--body-file` that cannot
be read, which gh reports itself. PRs opened through `gh api` or the web are
out of reach.
"""

from __future__ import annotations

import re
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Final

from hook_event import deny_output, parse_event
from shell_split import command_args, simple_commands

# A table cell holding a rating, and the line that names the winner.
_RATED_CELL: Final = re.compile(r"\|[^\n|]*[🟢🟡🟠🔴][^\n|]*\|")
_RECOMMENDATION: Final = re.compile(r"\brecommendation\b[*_]*:", re.IGNORECASE)
_NO_ALTERNATIVES: Final = re.compile(r"\bno alternatives\b", re.IGNORECASE)
_PR_VERBS: Final = frozenset({"create", "new", "edit"})
GUIDANCE: Final = (
    "Every PR description carries a decision matrix of the alternatives "
    "weighed (AGENTS.md): options as columns, criteria as rows, 🟢🟡🟠🔴 cells "
    "with a few-word reason, then a `Recommendation:` line. If there were no "
    "real alternatives, write one `No alternatives: <why>` line instead. Write "
    "the body to a file and pass `--body-file`."
)


def _pr_args(words: Sequence[str]) -> tuple[str, list[str]] | None:
    """Return the verb and options of a `gh pr create/edit`, or None."""

    args = command_args(words, "gh") or []
    if len(args) >= 2 and args[0] == "pr" and args[1] in _PR_VERBS:
        return args[1], args[2:]
    return None


def _option(options: Sequence[str], short: str, long: str) -> str | None:
    """Return the value of `-x v`, `-xv`, `--long v`, or `--long=v`, or None."""

    for index, option in enumerate(options):
        if option == "--":
            return None
        following = options[index + 1] if index + 1 < len(options) else ""
        if option in (short, long):
            return following
        if option.startswith(f"{long}="):
            return option.removeprefix(f"{long}=")
        if option.startswith(short) and not option.startswith("--"):
            return option.removeprefix(short)
    return None


def weighs_alternatives(body: str) -> bool:
    """Whether `body` holds a rated matrix and recommendation, or says none."""

    return bool(_NO_ALTERNATIVES.search(body)) or bool(
        _RATED_CELL.search(body) and _RECOMMENDATION.search(body)
    )


def _body_file_text(cwd: Path, name: str) -> str | None:
    """The text of a `--body-file`; `-` is stdin, already in the command."""

    if name == "-":
        return ""
    try:
        return (cwd / name).expanduser().read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def find_missing(cwd: Path, command: str) -> str | None:
    """Return why `command` sets a PR body that weighs no alternatives, or None."""

    try:
        commands = list(simple_commands(command))
    except ValueError:
        return None  # Unbalanced quotes: the shell itself will refuse it.
    for words in commands:
        found = _pr_args(words)
        if found is None:
            continue
        verb, options = found
        body = _option(options, "-b", "--body")
        body_file = _option(options, "-F", "--body-file")
        if body is None and body_file is None:
            web = "-w" in options or "--web" in options
            if verb == "edit" or web:
                continue
            return f"`gh pr {verb}` sets no `--body` or `--body-file`"
        file_text = _body_file_text(cwd, body_file) if body_file else ""
        if file_text is None:
            continue
        if not weighs_alternatives(f"{command}\n{file_text}"):
            return f"the `gh pr {verb}` body has no decision matrix"
    return None


def main() -> int:
    event = parse_event(sys.stdin.read())
    problem = find_missing(event.cwd, event.command or "")
    if problem is not None:
        print(deny_output(event, f"Blocked: {problem}. {GUIDANCE}"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
