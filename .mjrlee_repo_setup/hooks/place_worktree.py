"""WorktreeCreate/WorktreeRemove hook: Claude Code's worktrees in the home.

The home is `~/.worktrees/<repo>/` (`worktree_home.py`). With this hook,
Claude Code calls it instead of running git itself for `--worktree`, the
EnterWorktree tool, and subagent worktree isolation. Create prints the new
worktree's path as the only stdout line; any failure exits non-zero, which
fails the creation rather than falling back to `.claude/worktrees/`. Claude
Code then skips `.worktreeinclude`, and never deletes hook-made branches
itself, so removal deletes them here.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from typing import Final

import git_queries
import worktree_home
from hook_event import WorktreeEvent, parse_worktree_event

# Claude Code names worktrees like `bold-oak-a3f2`; a name is one path segment.
_NAME: Final = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
# Claude Code's own branch naming, so only branches made here are deleted.
BRANCH_PREFIX: Final = "worktree-"


class WorktreeError(Exception):
    """A refused or failed lifecycle step; the message is for the user."""


def _git(cwd: Path, *args: str) -> None:
    """Run git with its output on stderr, so stdout carries only the path."""

    result = subprocess.run(  # noqa: S603 - Fixed git argv, no shell.
        ["git", "-C", str(cwd), *args],  # noqa: S607 - git is on PATH.
        capture_output=True,
        text=True,
        check=False,
    )
    sys.stderr.write(result.stdout + result.stderr)
    if result.returncode != 0:
        msg = f"`git {' '.join(args)}` failed"
        raise WorktreeError(msg)


def _base(cwd: Path) -> str:
    """Return origin's freshly fetched default branch, else local HEAD."""

    default = git_queries.default_branch(cwd)
    if default is None:
        return "HEAD"
    # Offline, the last fetched copy is still a better base than HEAD.
    git_queries.run_git(cwd, "fetch", "--quiet", "origin", default)
    remote = f"origin/{default}"
    verified = git_queries.run_git(
        cwd, "rev-parse", "--verify", "--quiet", remote
    )
    return remote if verified else "HEAD"


def create(event: WorktreeEvent) -> Path:
    name = event.name or ""
    if not _NAME.fullmatch(name) or ".." in name:
        msg = (
            f"worktree name `{name}` must be one path segment of [A-Za-z0-9._-]"
        )
        raise WorktreeError(msg)
    try:
        home = worktree_home.home(event.cwd)
    except worktree_home.WorktreeHomeError as error:
        raise WorktreeError(str(error)) from error
    path = home / name
    if (path / ".git").exists():
        return path
    branch = f"{BRANCH_PREFIX}{name}"
    if git_queries.run_git(
        event.cwd, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"
    ):
        _git(event.cwd, "worktree", "add", str(path), branch)
    else:
        # No upstream: a bare `git push` must not target the base branch.
        _git(
            event.cwd,
            "worktree",
            "add",
            "--no-track",
            "-b",
            branch,
            str(path),
            _base(event.cwd),
        )
    return path


def remove(event: WorktreeEvent) -> None:
    path = event.worktree_path
    if path is None or not path.exists():
        git_queries.run_git(event.cwd, "worktree", "prune")
        return
    branch = git_queries.current_branch(path)
    # Never forced: uncommitted work fails the removal instead of vanishing.
    _git(event.cwd, "worktree", "remove", str(path))
    if branch and branch.startswith(BRANCH_PREFIX):
        # `-d` keeps branches with unmerged commits.
        git_queries.run_git(event.cwd, "branch", "-d", branch)


def main() -> int:
    try:
        event = parse_worktree_event(sys.stdin.read())
        if event.event_name == "WorktreeCreate":
            print(create(event))
        else:
            remove(event)
    except (ValueError, WorktreeError) as error:
        print(f"place_worktree: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
