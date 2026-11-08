"""Make a new checkout ready to build, test, and push.

Git's post-checkout hook runs this in each new linked worktree, so every
creator gets it: `git worktree add`, Claude Code (`place_worktree.py`),
`roadmap.py claim`, and a repo's own scripts. A fresh clone runs it by hand.
The steps are `[checkout] setup` in `repo.toml` (`repo_config.py`), else the
lockfile's frozen install. A failed step fails `git worktree add` and leaves
the worktree in place to fix and re-run:

    uv run --no-project python .mjrlee_repo_setup/hooks/setup_checkout.py

    setup_checkout.py <previous HEAD> <new HEAD> <branch-checkout flag>
"""

from __future__ import annotations

import shlex
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Final

import git_queries
from repo_config import RepoConfigError, load

RERUN: Final = (
    "uv run --no-project python .mjrlee_repo_setup/hooks/setup_checkout.py"
)


def is_new_worktree(cwd: Path, previous: str, flag: str) -> bool:
    """Return True for a linked worktree `git worktree add` just checked out.

    Stray worktrees are skipped: `worktree_rules.py` removes them.
    """

    if not git_queries.is_null_sha(previous) or flag != "1":
        return False
    top = git_queries.repo_root(cwd)
    main = git_queries.main_checkout(cwd)
    return (
        top is not None
        and main is not None
        and git_queries.is_linked_worktree(cwd) is True
        and git_queries.is_allowed_worktree(top, main)
    )


def setup(root: Path) -> int:
    """Run each setup step from `root`; stop at the first that fails."""

    def fail(why: str) -> int:
        print(
            f"setup_checkout: {why}. Fix it, then run `{RERUN}` in {root}.",
            file=sys.stderr,
        )
        return 1

    try:
        steps = load(root).setup
    except RepoConfigError as error:
        return fail(str(error))
    for argv in steps:
        shown = shlex.join(argv)
        print(f"setup_checkout: {shown}", file=sys.stderr)
        try:
            # Stdout joins stderr so callers that read a path from stdout,
            # like Claude Code's WorktreeCreate hook, see only that path.
            code = subprocess.run(  # noqa: S603 - Argv from the repo's config.
                argv, cwd=root, stdout=sys.stderr, check=False
            ).returncode
        except OSError as error:
            return fail(f"`{shown}` could not start ({error.strerror})")
        if code != 0:
            return fail(f"`{shown}` exited {code}")
    return 0


def main(argv: Sequence[str]) -> int:
    cwd = Path.cwd()
    if argv and (len(argv) != 3 or not is_new_worktree(cwd, argv[0], argv[2])):
        return 0
    root = git_queries.repo_root(cwd)
    if root is None:
        print(f"setup_checkout: {cwd} is not a git checkout", file=sys.stderr)
        return 1
    return setup(root)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
