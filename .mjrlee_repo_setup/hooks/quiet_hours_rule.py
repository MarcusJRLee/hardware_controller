"""Git hooks and CLI for quiet hours (`quiet_hours.py`, `repo.toml`).

    quiet_hours_rule.py                         # Whether quiet hours are on now.
    quiet_hours_rule.py pre-commit              # Refuse a commit inside them.
    quiet_hours_rule.py pre-push <remote> <url> # Ref lines on stdin.
    quiet_hours_rule.py audit [<rev>...]        # Commits dated inside them.

pre-commit gives early feedback. pre-push is the authority: besides refusing
any push inside a window, it refuses every pushed commit whose author or
committer date falls in one, which covers merges, rebases, cherry-picks, and
commits made where the hooks were not installed. A rebase after a window keeps
the author date, so work done inside one stays refused. Undeclared quiet hours
block nothing here; verify reports them.
"""

from __future__ import annotations

import sys
from collections.abc import Iterable, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Final

import git_queries
from quiet_hours import QuietHours
from repo_config import CONFIG, RepoConfigError, load

# Bounds each `git log` argv, so a large push never nears ARG_MAX.
_CHUNK: Final = 500


def hours_at(cwd: Path) -> QuietHours | None:
    root = git_queries.repo_root(cwd)
    return load(root).quiet_hours if root else None


def now_blocked(hours: QuietHours, now: datetime, action: str) -> str | None:
    """Return why `action` is refused at `now`, or None outside a window."""

    until = hours.quiet_until(now)
    if until is None:
        return None
    return (
        f"Blocked: quiet hours are on until {hours.describe(until)} "
        f"({CONFIG} [quiet_hours]); {action} after they end"
    )


def dated_inside(
    hours: QuietHours, commits: Iterable[git_queries.CommitDates]
) -> list[str]:
    """Describe each commit with a date inside a window, e.g. `ab12 authored`."""

    found: list[str] = []
    for commit in commits:
        dates = (("authored", commit.authored), ("committed", commit.committed))
        inside = [
            f"{what} {hours.describe(at)}"
            for what, stamp in dates
            if hours.quiet_until(at := datetime.fromtimestamp(stamp, UTC))
        ]
        if inside:
            found.append(f"{commit.sha[:12]} ({', '.join(inside)})")
    return found


def pushed_dates(
    lines: Iterable[str], cwd: Path
) -> list[git_queries.CommitDates]:
    commits = git_queries.pushed_commits(lines, cwd)
    return [
        dates
        for n in range(0, len(commits), _CHUNK)
        for dates in git_queries.commit_dates(
            cwd, "--no-walk=unsorted", *commits[n : n + _CHUNK]
        )
    ]


DATED_HINT: Final = (
    "Quiet hours forbid commits dated inside them, and the kit never rewrites"
    " commit dates"
)


def pre_push(lines: Iterable[str], cwd: Path, now: datetime) -> list[str]:
    hours = hours_at(cwd)
    if hours is None or not hours.windows:
        return []
    blocked = now_blocked(hours, now, "push")
    if blocked is not None:
        return [blocked]
    inside = dated_inside(hours, pushed_dates(lines, cwd))
    if not inside:
        return []
    return [
        f"Blocked: dated inside quiet hours: {'; '.join(inside)}. {DATED_HINT}"
    ]


def status(hours: QuietHours | None, now: datetime) -> str:
    if hours is None:
        return f"No quiet hours declared in {CONFIG}."
    if not hours.windows:
        return "This repo has no quiet hours."
    until = hours.quiet_until(now)
    if until is not None:
        return f"Quiet hours are on until {hours.describe(until)}."
    start = hours.next_start(now)
    tail = f"; next from {hours.describe(start)}" if start else ""
    return f"Quiet hours are off{tail}."


def run(
    argv: Sequence[str], stdin: Iterable[str], now: datetime, cwd: Path
) -> int:
    command = argv[0] if argv else "status"
    if command == "pre-commit":
        # A broken repo.toml must stay committable, or nothing could fix it;
        # pre-push still refuses it.
        try:
            hours = hours_at(cwd)
        except RepoConfigError as error:
            print(f"quiet_hours_rule: {error}", file=sys.stderr)
            return 0
        found = [now_blocked(hours, now, "commit")] if hours else []
    elif command == "pre-push":
        found = pre_push(stdin, cwd, now)
    elif command == "audit":
        hours = hours_at(cwd)
        dates = git_queries.commit_dates(cwd, *(argv[1:] or ["HEAD"]))
        found = dated_inside(hours, dates) if hours else []
    elif command == "status":
        print(status(hours_at(cwd), now))
        return 0
    else:
        print(__doc__, file=sys.stderr)
        return 2
    messages = [m for m in found if m]
    for message in messages:
        print(message, file=sys.stderr if command != "audit" else sys.stdout)
    return 1 if messages else 0


def main() -> int:
    try:
        return run(sys.argv[1:], sys.stdin, datetime.now(UTC), Path.cwd())
    except RepoConfigError as error:
        print(f"quiet_hours_rule: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
