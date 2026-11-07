"""Git post-checkout hook: where checkouts live and what the main one holds.

Git runs this inside each new worktree, so the verdict uses its real path: no
command parsing. A worktree outside the main checkout's allowed dirs
(`git_queries.ALLOWED_WORKTREE_DIRS`: `.worktrees/`, plus Claude desktop's
`.claude/worktrees/`) is removed again and `git worktree add` fails.

The main checkout stays on the default branch, since repos may run live code
from it: a switch elsewhere is switched back and the command fails. Rebase and
bisect detach HEAD on purpose and are left alone.

    worktree_rules.py <previous HEAD> <new HEAD> <branch-checkout flag>
"""

from __future__ import annotations

import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Final

import git_queries

# Git state dirs or files present while an operation detaches HEAD on purpose.
DETACHING_OPERATIONS: Final = ("rebase-merge", "rebase-apply", "BISECT_START")


def check(cwd: Path, previous: str, flag: str) -> Path | None:
    """Return this checkout's root when it is a stray worktree to remove."""

    # Only `git worktree add` (and clone) check out from the null commit.
    if not git_queries.is_null_sha(previous) or flag != "1":
        return None
    git_dir = git_queries.run_git(cwd, "rev-parse", "--absolute-git-dir")
    common = git_queries.run_git(
        cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"
    )
    top = git_queries.repo_root(cwd)
    main = git_queries.main_checkout(cwd)
    if git_dir is None or common is None or top is None or main is None:
        return None
    if Path(git_dir).resolve() == Path(common).resolve():
        return None
    return None if git_queries.is_allowed_worktree(top, main) else top


def home_branch(cwd: Path, flag: str) -> str | None:
    """Return the branch to send the main checkout back to, if it left it."""

    if flag != "1":
        return None
    git_dir = git_queries.run_git(cwd, "rev-parse", "--absolute-git-dir")
    common = git_queries.run_git(
        cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"
    )
    if git_dir is None or common is None:
        return None
    if Path(git_dir).resolve() != Path(common).resolve():
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
        f"a worktree: `git worktree add -b <branch> .worktrees/<name> "
        f"origin/{branch}`.",
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
    home = git_queries.worktree_dir(stray)
    if home is not None:
        git_queries.run_git(
            home.parent, "worktree", "remove", "--force", str(stray)
        )
    print(
        f"Blocked: removed worktree {stray}. Create worktrees only as "
        f"`{home}/<name>`.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
