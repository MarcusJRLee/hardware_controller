"""Where a repo's linked worktrees live: `~/.worktrees/<repo>/<name>`.

`<repo>` is the main checkout's directory name. Outside the checkout, no file
watcher, indexer, or linter on the checkout covers a worktree, and one folder
holds every repo's worktrees. Every kit module that creates, checks, or lists
worktrees asks this module; kit directories that may not import it run it as
a command. `MJRLEE_WORKTREE_HOME` replaces `~/.worktrees`, so tests never touch
the real home.

Two clones with the same directory name would share one folder, so a folder
that already holds another repository's worktrees is refused, never mixed.

    worktree_home.py          # Print this repo's worktree home.
    worktree_home.py strays   # Print its linked worktrees outside the home.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Final

import git_queries

ENV: Final = "MJRLEE_WORKTREE_HOME"


class WorktreeHomeError(Exception):
    """The home cannot be used; the message says why and what to do."""


def root() -> Path:
    """Return the folder that holds one worktree home per repo."""

    raw = os.environ.get(ENV, "")
    if not raw:
        return Path.home() / ".worktrees"
    path = Path(raw).expanduser()
    if not path.is_absolute():
        msg = f"{ENV}={raw} must be an absolute path"
        raise WorktreeHomeError(msg)
    return path


@dataclass(frozen=True)
class Repo:
    # Both resolved, so symlinks cannot disguise a location.
    main: Path
    common: Path

    @property
    def home(self) -> Path:
        return (root() / self.main.name).resolve()


def locate(cwd: Path) -> Repo | None:
    """Return the repo `cwd` is in, from any of its worktrees."""

    common = git_queries.run_git(
        cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"
    )
    if not common:
        return None
    resolved = Path(common).resolve()
    return Repo(resolved.parent, resolved)


def owner(checkout: Path) -> Path | None:
    """Return the git common dir `checkout` belongs to; None if not a checkout.

    Reads `.git` directly: a clone's is its own repository, and a linked
    worktree's names its git dir, whose `commondir` names the repository.
    """

    dot_git = checkout / ".git"
    if dot_git.is_dir():
        return dot_git.resolve()
    try:
        text = dot_git.read_text(encoding="utf-8")
    except OSError:
        return None
    if not text.startswith("gitdir: "):
        return None
    git_dir = checkout / text.removeprefix("gitdir: ").strip()
    try:
        common = (git_dir / "commondir").read_text(encoding="utf-8").strip()
    except OSError:
        # The repository is gone; its layout is `<common>/worktrees/<id>`.
        return git_dir.resolve().parent.parent
    return (git_dir / common).resolve()


def unusable(repo: Repo) -> str | None:
    """Explain why `repo` may not use its home, or None when it may."""

    home = repo.home
    if home.is_relative_to(repo.main):
        return f"{home} is inside the main checkout {repo.main}; set {ENV} elsewhere"
    if not home.is_dir():
        return None
    for child in sorted(home.iterdir()):
        other = owner(child) if child.is_dir() else None
        if other is not None and other != repo.common:
            return (
                f"{home} already holds {child}, a worktree of {other}, whose "
                f"main checkout is also named `{repo.main.name}`. Rename one "
                f"main checkout's directory, or `git worktree move` that "
                f"worktree out, then retry"
            )
    return None


def home(cwd: Path) -> Path:
    """Return the dir new worktrees of `cwd`'s repo go in, ready to use."""

    repo = locate(cwd)
    if repo is None:
        msg = f"{cwd} is not inside a git repository"
        raise WorktreeHomeError(msg)
    shared = unusable(repo)
    if shared is not None:
        raise WorktreeHomeError(shared)
    return repo.home


def refusal(path: Path, repo: Repo) -> str | None:
    """Return why `path` may not be a linked worktree of `repo`, or None.

    Only a direct child of the home passes, so `<home>/a/b` never does.
    """

    if path.resolve().parent == repo.home:
        return unusable(repo)
    return f"worktrees go in {repo.home}/<name>"


def strays(repo: Repo) -> list[Path]:
    """Return `repo`'s registered linked worktrees that `refusal` rejects."""

    listing = git_queries.run_git(repo.main, "worktree", "list", "--porcelain")
    paths = [
        Path(line.removeprefix("worktree "))
        for line in (listing or "").splitlines()
        if line.startswith("worktree ")
    ]
    # Git lists the main checkout first.
    return [p for p in paths[1:] if refusal(p, repo) is not None]


def main(argv: Sequence[str]) -> int:
    cwd = Path.cwd()
    try:
        if not argv:
            print(home(cwd))
            return 0
        if list(argv) == ["strays"]:
            repo = locate(cwd)
            if repo is None:
                msg = f"{cwd} is not inside a git repository"
                raise WorktreeHomeError(msg)
            for path in strays(repo):
                print(path)
            return 0
    except WorktreeHomeError as error:
        print(f"worktree_home: {error}", file=sys.stderr)
        return 1
    print("usage: worktree_home.py [strays]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
