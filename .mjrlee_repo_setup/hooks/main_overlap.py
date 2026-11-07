"""Git pre-push hook: warn when the default branch changed files a push changes.

Parallel threads fix the same thing; this names each change that landed on the
default branch since a pushed branch's merge base and touched a file the branch
also changes, so a duplicate shows up before its PR does. It fetches the
default branch from `origin` first, warns and never blocks, and stays silent
when the fetch fails (offline) or nothing overlaps.

    main_overlap.py <remote> <url>   # Ref lines on stdin, as git sends them.
"""

from __future__ import annotations

import re
import sys
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Final

import git_queries

# Bounds a hung network so a push never waits on the warning for long.
FETCH_TIMEOUT_SECONDS: Final = 15
# GitHub's squash merges end the subject with ` (#N)`; merge commits start
# with `Merge pull request #N`.
SQUASH_SUFFIX: Final = re.compile(r" \(#(\d+)\)$")
MERGE_PREFIX: Final = re.compile(r"^Merge pull request #(\d+) ")


@dataclass(frozen=True)
class Change:
    """One first-parent commit on the default branch: usually one merged PR."""

    sha: str
    subject: str
    files: frozenset[str]

    @property
    def label(self) -> str:
        """Return the PR as `#N`, or the short sha when none is named."""

        found = SQUASH_SUFFIX.search(self.subject) or MERGE_PREFIX.search(
            self.subject
        )
        return f"#{found.group(1)}" if found else self.sha[:12]

    @property
    def title(self) -> str:
        return SQUASH_SUFFIX.sub("", self.subject)


def overlaps(lines: Iterable[str], cwd: Path) -> dict[str, list[Change]]:
    """Map each pushed branch to the default-branch changes sharing its files.

    Each returned change keeps only the files it shares with the branch.
    """

    pushed = pushed_branches(lines, cwd)
    if not pushed:
        return {}
    default = git_queries.default_branch(cwd)
    if default is None or not fetch_default(cwd, default):
        return {}
    upstream = f"refs/remotes/origin/{default}"
    found: dict[str, list[Change]] = {}
    for branch, sha in pushed.items():
        if branch == default:
            continue
        shared = shared_changes(cwd, sha, upstream)
        if shared:
            found[branch] = shared
    return found


def pushed_branches(lines: Iterable[str], cwd: Path) -> dict[str, str]:
    """Map each branch the push creates or updates to its new local commit."""

    pushed: dict[str, str] = {}
    for line in lines:
        parts = line.split()
        if len(parts) != 4:
            continue
        _, local_sha, remote_ref, _ = parts
        if git_queries.is_null_sha(local_sha) or not remote_ref.startswith(
            "refs/heads/"
        ):
            continue
        # A pushed tag object or other non-commit has no history to compare.
        if (
            git_queries.run_git(
                cwd, "cat-file", "-e", f"{local_sha}^{{commit}}"
            )
            is None
        ):
            continue
        pushed[remote_ref.removeprefix("refs/heads/")] = local_sha
    return pushed


def fetch_default(cwd: Path, default: str) -> bool:
    """Update `origin/<default>`; False when origin is unreachable."""

    refspec = f"+refs/heads/{default}:refs/remotes/origin/{default}"
    return (
        git_queries.run_git(
            cwd,
            "-c",
            "credential.interactive=false",
            "fetch",
            "--quiet",
            "--no-tags",
            "--no-write-fetch-head",
            "origin",
            refspec,
            timeout=FETCH_TIMEOUT_SECONDS,
        )
        is not None
    )


def shared_changes(cwd: Path, sha: str, upstream: str) -> list[Change]:
    """Return upstream changes since the merge base that touch `sha`'s files."""

    base = git_queries.run_git(cwd, "merge-base", sha, upstream)
    if base is None:
        return []
    # `--no-renames` lists both sides of a rename, so a move overlaps too.
    diff = git_queries.run_git(
        cwd, "diff", "--name-only", "--no-renames", base, sha
    )
    branch_files = frozenset((diff or "").splitlines())
    if not branch_files:
        return []
    shared: list[Change] = []
    for change in changes(cwd, f"{base}..{upstream}"):
        files = change.files & branch_files
        if files:
            shared.append(Change(change.sha, change.subject, files))
    return shared


def changes(cwd: Path, revisions: str) -> list[Change]:
    """Return first-parent commits in `revisions`, newest first, with files.

    A merge commit lists the files it brought in relative to its first parent,
    so a merged PR is one change whether it was squashed or merged.
    """

    log = git_queries.run_git(
        cwd,
        "log",
        "--first-parent",
        "--diff-merges=first-parent",
        "--no-renames",
        "--name-only",
        "--format=%x00%H%x00%s",
        revisions,
    )
    fields = (log or "").split("\0")[1:]
    found: list[Change] = []
    for sha, body in zip(fields[::2], fields[1::2], strict=True):
        subject, *files = body.splitlines() or [""]
        found.append(Change(sha, subject, frozenset(f for f in files if f)))
    return found


def report(found: dict[str, list[Change]]) -> str:
    lines: list[str] = []
    for branch, shared in found.items():
        lines.append(
            f"Warning: origin's default branch changed files `{branch}` also "
            "changes since it branched; check for a duplicate fix, then "
            "rebase onto it:"
        )
        for change in shared:
            lines.append(f"  {change.label} {change.title}")
            lines.extend(f"      {path}" for path in sorted(change.files))
    return "\n".join(lines)


def main() -> int:
    found = overlaps(sys.stdin.read().splitlines(), Path.cwd())
    if found:
        print(report(found), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
