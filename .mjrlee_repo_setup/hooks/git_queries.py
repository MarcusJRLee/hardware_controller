"""Git queries shared by repo hooks."""

from __future__ import annotations

import subprocess
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Final

# The rule every push block cites; it mirrors the [Git] rule in AGENTS.md.
PR_RULE: Final = (
    "Repo rules require a dedicated branch and a pull request. If the user "
    "explicitly approves an exception, they push it themselves."
)
ALWAYS_PROTECTED: Final = frozenset({"main", "master"})


def is_null_sha(sha: str) -> bool:
    """Return True for git's all-zero object id (SHA-1 or SHA-256)."""

    return bool(sha) and set(sha) == {"0"}


def run_git(cwd: Path, *args: str, timeout: float | None = None) -> str | None:
    """Return stripped stdout, or None when git fails, is missing, or hangs.

    Git never reads the hook's stdin, which carries the hook's own input.
    """

    try:
        result = subprocess.run(  # noqa: S603 - Fixed git argv, no shell.
            ["git", "-C", str(cwd), *args],  # noqa: S607 - git is on PATH.
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def repo_root(cwd: Path) -> Path | None:
    root = run_git(cwd, "rev-parse", "--show-toplevel")
    return Path(root).resolve() if root else None


def main_checkout(cwd: Path) -> Path | None:
    """Return the main checkout's root, from any of its worktrees."""

    common = run_git(
        cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"
    )
    return Path(common).resolve().parent if common else None


# What each marker in a worktree's own git dir means: an operation that
# checks out commits is unfinished there.
IN_PROGRESS: Final = (
    ("rebase-merge", "a rebase"),
    ("rebase-apply", "a rebase or `git am`"),
    ("MERGE_HEAD", "a merge"),
    ("CHERRY_PICK_HEAD", "a cherry-pick"),
    ("REVERT_HEAD", "a revert"),
    ("sequencer", "a cherry-pick or revert sequence"),
)


def operation_in_progress(cwd: Path) -> str | None:
    """Return the unfinished rebase, merge, pick, or revert here, or None.

    Reads the worktree's own git dir, so one linked worktree's rebase never
    counts against another or the main checkout.
    """

    git_dir = run_git(cwd, "rev-parse", "--absolute-git-dir")
    if git_dir is None:
        return None
    return next(
        (what for name, what in IN_PROGRESS if (Path(git_dir) / name).exists()),
        None,
    )


def is_linked_worktree(cwd: Path) -> bool | None:
    """Return True in a linked worktree, False in the main checkout, else None."""

    git_dir = run_git(cwd, "rev-parse", "--absolute-git-dir")
    common = run_git(
        cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"
    )
    if git_dir is None or common is None:
        return None
    return Path(git_dir).resolve() != Path(common).resolve()


def pushed_commits(lines: Iterable[str], cwd: Path) -> list[str]:
    """Return the commits a pre-push sends that no origin branch has yet.

    `lines` are git's pre-push ref lines; deletions send no commits.
    """

    found: list[str] = []
    for line in lines:
        parts = line.split()
        if len(parts) != 4 or is_null_sha(parts[1]):
            continue
        listed = run_git(cwd, "rev-list", parts[1], "--not", "--remotes=origin")
        found.extend(c for c in (listed or "").split() if c not in found)
    return found


@dataclass(frozen=True)
class CommitDates:
    sha: str
    # Unix seconds; git stores both with their own offset, which no rule uses.
    authored: int
    committed: int


def commit_dates(cwd: Path, *log_args: str) -> list[CommitDates]:
    """Return each commit `git log <log_args>` lists, with its two dates."""

    out = run_git(cwd, "log", "--format=%H %at %ct", *log_args)
    found: list[CommitDates] = []
    for line in (out or "").splitlines():
        sha, authored, committed = line.split()
        found.append(CommitDates(sha, int(authored), int(committed)))
    return found


def current_branch(cwd: Path) -> str | None:
    """Return the checked-out branch, or None when detached or not a repo."""

    return run_git(cwd, "branch", "--show-current") or None


def default_branch(cwd: Path) -> str | None:
    """Return the remote default branch name from `origin/HEAD`, if known."""

    ref = run_git(
        cwd, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"
    )
    return ref.removeprefix("origin/") if ref else None


def protected_branches(cwd: Path) -> frozenset[str]:
    names = set(ALWAYS_PROTECTED)
    default = default_branch(cwd)
    if default:
        names.add(default)
    return frozenset(names)


def is_known_path(root: Path, path: Path) -> bool:
    """Return True when `path` is tracked or ignored, meaning not newly authored."""

    rel = str(path.relative_to(root))
    if run_git(root, "ls-files", "--", rel):
        return True
    return run_git(root, "check-ignore", "--quiet", "--", rel) is not None
