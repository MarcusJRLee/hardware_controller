"""Git pre-push hook: refuse pushes the kit's [Git] rules forbid.

Git hands this hook every ref it is about to push, so the verdict uses the
real refs: no command parsing. Blocks updating or deleting a protected branch.
A force push (an update that is not a fast-forward) passes only to another
branch, and only when the remote tip is one this branch held before, per its
reflog: the checks `--force-with-lease --force-if-includes` make, whatever
flags were typed, so rebasing a stacked branch works and nobody's commits are
overwritten unseen. Git names the local ref as typed, so `git push origin HEAD`
arrives as `HEAD`, judged by the branch it points at; a detached `HEAD` has no
branch reflog and is refused. Lefthook runs it as a script, which unlike a command runs
even when a push changes no files.

    push_rules.py <remote> <url>   # Ref lines on stdin, as git sends them.
"""

from __future__ import annotations

import sys
from collections.abc import Iterable
from pathlib import Path

import git_queries


def violations(lines: Iterable[str], cwd: Path) -> list[str]:
    """Return one reason per refused ref; empty means the push may proceed."""

    protected = git_queries.protected_branches(cwd)
    found: list[str] = []
    for line in lines:
        parts = line.split()
        if len(parts) != 4:
            continue
        local_ref, local_sha, remote_ref, remote_sha = parts
        branch = remote_ref.removeprefix("refs/heads/")
        if remote_ref.startswith("refs/heads/") and branch in protected:
            verb = "delete" if git_queries.is_null_sha(local_sha) else "push to"
            found.append(f"{verb} protected branch `{branch}`")
        elif git_queries.is_null_sha(local_sha) or git_queries.is_null_sha(
            remote_sha
        ):
            continue
        elif (
            git_queries.run_git(
                cwd, "cat-file", "-e", f"{remote_sha}^{{commit}}"
            )
            is None
        ):
            # Without the remote commit, a force push is indistinguishable.
            found.append(
                f"`{remote_ref}` moved on the remote; fetch, then push"
            )
        elif (
            git_queries.run_git(
                cwd, "merge-base", "--is-ancestor", remote_sha, local_sha
            )
            is not None
        ):
            continue
        elif not remote_ref.startswith("refs/heads/"):
            found.append(f"force push to `{remote_ref}`")
        elif reason := unheld(cwd, local_ref, remote_ref, remote_sha):
            found.append(reason)
    return found


def unheld(
    cwd: Path, local_ref: str, remote_ref: str, remote_sha: str
) -> str | None:
    """Return why force-pushing `local_ref` over `remote_sha` is refused."""

    branch_ref = local_branch(cwd, local_ref)
    if branch_ref is None and local_ref == "HEAD":
        return (
            f"force push to `{remote_ref}` from a detached `HEAD`, which no "
            "branch reflog vouches for; check out the branch, then push"
        )
    if branch_ref is not None and remote_sha in held_tips(cwd, branch_ref):
        return None
    return (
        f"force push to `{remote_ref}` would drop {remote_sha[:12]}, which "
        f"`{branch_ref or local_ref}` never held; fetch and integrate it first"
    )


def local_branch(cwd: Path, local_ref: str) -> str | None:
    """Return the `refs/heads/` branch `local_ref` names, or None.

    Symbolic refs, `HEAD` included, resolve to their target. `HEAD`'s own
    reflog is never used: it also records every other branch checked out.
    """

    target = (
        git_queries.run_git(cwd, "symbolic-ref", "-q", local_ref) or local_ref
    )
    return target if target.startswith("refs/heads/") else None


def held_tips(cwd: Path, branch_ref: str) -> frozenset[str]:
    """Return every commit `branch_ref` has pointed at, from its reflog."""

    log = git_queries.run_git(
        cwd, "log", "--walk-reflogs", "--format=%H", branch_ref
    )
    return frozenset((log or "").split())


def main() -> int:
    found = violations(sys.stdin.read().splitlines(), Path.cwd())
    for reason in found:
        print(f"Blocked: {reason}. {git_queries.PR_RULE}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
