"""Git queries shared by repo hooks."""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Final

# Where agents and people create worktrees, so every one is findable from the
# repo; place_worktree.py routes Claude Code's own worktrees here too.
WORKTREE_DIR: Final = Path(".worktrees")
# Claude desktop's in-project worktree dir. Its settings offer only this or a
# folder outside every repo, so the kit allows it rather than fight the app.
DESKTOP_WORKTREE_DIR: Final = Path(".claude") / "worktrees"
# Every dir, relative to the main checkout, whose children may be worktrees.
ALLOWED_WORKTREE_DIRS: Final = (WORKTREE_DIR, DESKTOP_WORKTREE_DIR)


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


def is_linked_worktree(cwd: Path) -> bool | None:
    """Return True in a linked worktree, False in the main checkout, else None."""

    git_dir = run_git(cwd, "rev-parse", "--absolute-git-dir")
    common = run_git(
        cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"
    )
    if git_dir is None or common is None:
        return None
    return Path(git_dir).resolve() != Path(common).resolve()


def worktree_dir(cwd: Path) -> Path | None:
    """Return the dir new worktrees go in, from any worktree of the repo."""

    main = main_checkout(cwd)
    return main / WORKTREE_DIR if main else None


def is_allowed_worktree(path: Path, main: Path) -> bool:
    """Return True when `path` is `<main>/<allowed dir>/<name>`.

    Both sides are resolved, so a symlinked parent cannot disguise a stray
    path, and a nested path such as `.worktrees/a/b` is never allowed.
    """

    parent = path.resolve().parent
    root = main.resolve()
    return any(parent == root / d for d in ALLOWED_WORKTREE_DIRS)


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
