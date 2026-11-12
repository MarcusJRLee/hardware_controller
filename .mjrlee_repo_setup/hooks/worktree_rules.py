"""Git post-checkout hook: where checkouts live and what the main one holds.

Git runs this inside each new worktree, so the verdict uses its real path: no
command parsing. A worktree outside the repo's worktree home
(`worktree_home.py`: `~/.worktrees/<repo>/`), or in a home another repository
already uses, is removed again and `git worktree add` fails.

The main checkout stays on the default branch, since repos may run live code
from it: a switch elsewhere is switched back and the command fails. Rebase and
bisect detach HEAD on purpose and are left alone.

    worktree_rules.py <previous HEAD> <new HEAD> <branch-checkout flag>
"""

from __future__ import annotations

import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Final

import git_queries
import worktree_home

# Git state dirs or files present while an operation detaches HEAD on purpose.
DETACHING_OPERATIONS: Final = ("rebase-merge", "rebase-apply", "BISECT_START")


@dataclass(frozen=True)
class Stray:
    """A new worktree to remove, and why."""

    path: Path
    main: Path
    reason: str


def check(cwd: Path, previous: str, flag: str) -> Stray | None:
    """Return this checkout when it is a stray worktree to remove."""

    # Only `git worktree add` (and clone) check out from the null commit.
    if not git_queries.is_null_sha(previous) or flag != "1":
        return None
    top = git_queries.repo_root(cwd)
    repo = worktree_home.locate(cwd)
    if top is None or repo is None or not git_queries.is_linked_worktree(cwd):
        return None
    try:
        reason = worktree_home.refusal(top, repo)
    except worktree_home.WorktreeHomeError as error:
        reason = str(error)
    return None if reason is None else Stray(top, repo.main, reason)


def add_hint(cwd: Path, branch: str) -> str:
    """Return the command that makes a worktree where it belongs."""

    try:
        home = worktree_home.home(cwd)
    except worktree_home.WorktreeHomeError:
        home = Path("~/.worktrees/<repo>")
    return f"git worktree add -b <branch> {home}/<name> origin/{branch}"


def home_branch(cwd: Path, flag: str) -> str | None:
    """Return the branch to send the main checkout back to, if it left it."""

    if flag != "1":
        return None
    if git_queries.is_linked_worktree(cwd) is not False:
        return None
    git_dir = git_queries.run_git(cwd, "rev-parse", "--absolute-git-dir")
    if git_dir is None:
        return None
    if any((Path(git_dir) / name).exists() for name in DETACHING_OPERATIONS):
        return None
    default = git_queries.default_branch(cwd) or next(
        (
            name
            for name in sorted(git_queries.ALWAYS_PROTECTED)
            if git_queries.run_git(
                cwd, "rev-parse", "--verify", "--quiet", f"refs/heads/{name}"
            )
        ),
        None,
    )
    if default is None or git_queries.current_branch(cwd) == default:
        return None
    return default


def return_home(cwd: Path, branch: str) -> int:
    """Switch the main checkout back to `branch` and explain the block."""

    switched = git_queries.run_git(cwd, "checkout", "--quiet", branch)
    outcome = (
        f"switched back to `{branch}`"
        if switched is not None
        else f"could not switch back; run `git switch {branch}` now"
    )
    print(
        f"Blocked: the main checkout stays on `{branch}` ({outcome}). Work in "
        f"a worktree: `{add_hint(cwd, branch)}`.",
        file=sys.stderr,
    )
    return 1


def main(argv: Sequence[str]) -> int:
    if len(argv) != 3:
        return 0
    cwd = Path.cwd()
    branch = home_branch(cwd, argv[2])
    if branch is not None:
        return return_home(cwd, branch)
    stray = check(cwd, argv[0], argv[2])
    if stray is None:
        return 0
    git_queries.run_git(
        stray.main, "worktree", "remove", "--force", str(stray.path)
    )
    print(
        f"Blocked: removed worktree {stray.path}: {stray.reason}.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
