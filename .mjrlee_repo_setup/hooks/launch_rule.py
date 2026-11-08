"""Git pre-push hook: after public launch, every commit names its flag.

Once `repo.toml` sets `[launch] phase = "public"`, service must never be
interrupted, so each behavior change ships behind a flag. Every commit the
push sends that no origin branch has needs a `Flag:` trailer: the flag's
catalog name, or `none (<reason>)` for a change no flag can gate (docs, tests,
the flag catalog itself). Merge commits carry their parents' trailers. Before
launch the rule is off; a repo that declares no phase cannot push.

    launch_rule.py <remote> <url>   # Ref lines on stdin, as git sends them.
"""

from __future__ import annotations

import re
import sys
from collections.abc import Iterable
from pathlib import Path
from typing import Final

import git_queries
from repo_config import UNDECLARED, RepoConfigError, load

TRAILER: Final = "Flag"
# A catalog name, or `none` with a reason in parentheses.
_VALUE: Final = re.compile(r"none \(\S.*\)|(?!none\b)[A-Za-z0-9][\w.:-]*")
GUIDANCE: Final = (
    "After public launch every commit names the flag that gates it: add a "
    f"`{TRAILER}: <flag>` trailer, or `{TRAILER}: none (<reason>)` when no "
    "flag can gate it (AGENTS.md [Launch])"
)


def flag_values(cwd: Path, commit: str) -> list[str]:
    trailers = git_queries.run_git(
        cwd,
        "log",
        "-1",
        f"--format=%(trailers:key={TRAILER},valueonly,separator=%x00)",
        commit,
    )
    return [v.strip() for v in (trailers or "").split("\0") if v.strip()]


def is_merge(cwd: Path, commit: str) -> bool:
    parents = git_queries.run_git(cwd, "log", "-1", "--format=%P", commit)
    return len((parents or "").split()) > 1


def violations(lines: Iterable[str], cwd: Path) -> list[str]:
    root = git_queries.repo_root(cwd)
    if root is None:
        return []
    config = load(root)
    if config.phase is None:
        return [UNDECLARED]
    if not config.public:
        return []
    found: list[str] = []
    for commit in git_queries.pushed_commits(lines, cwd):
        if is_merge(cwd, commit):
            continue
        values = flag_values(cwd, commit)
        if not values:
            found.append(f"{commit[:12]} has no `{TRAILER}:` trailer")
        elif not all(_VALUE.fullmatch(v) for v in values):
            found.append(
                f"{commit[:12]} has a malformed `{TRAILER}:` trailer "
                f"({'; '.join(values)})"
            )
    return found


def main() -> int:
    try:
        found = violations(sys.stdin.read().splitlines(), Path.cwd())
    except RepoConfigError as error:
        print(f"launch_rule: {error}", file=sys.stderr)
        return 1
    if not found:
        return 0
    print(f"Blocked: {'; '.join(found)}. {GUIDANCE}.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
