"""Merge a PR only when its branch holds its base's latest commit.

    uv run --no-project python .mjrlee_repo_setup/tools/merge_pr.py <number>
    ... merge_pr.py <number> --merge     # Any other `gh pr merge` flags pass on.

GitHub calls a PR mergeable when its diff applies, not when its checks ran on
the result. Two PRs that each pass alone can still break the base together, so
this refuses a PR whose branch is behind its base: rebase it, push (the
pre-push hook runs the checks on the combined code), and merge again.

It decides on the branch's tip as the git server reports it (`git ls-remote`),
which is current the moment a push returns, never on the PR's recorded head,
which GitHub updates a few seconds later. So every refusal is immediate and
exact: a local branch that differs from the server's, or a tip behind the
base. The one wait left is for GitHub's PR head to reach that tip, since the
merge itself is GitHub's, and `--match-head-commit` makes it merge exactly the
commit checked or fail. A PR from a fork, whose branch is not on `origin`, is
checked at its recorded head.

A repo adopts it in `.mjrlee_repo_setup/repo.toml`, which makes the kit's
`guard_git.py` deny a plain `gh pr merge`:

    [replace]
    "gh pr merge" = "uv run --no-project python .mjrlee_repo_setup/tools/merge_pr.py <number>"
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from urllib.parse import quote

# Runs argv and returns its exit code and stdout; stderr passes through.
Run = Callable[[Sequence[str]], tuple[int, str]]
Sleep = Callable[[float], None]

# How long GitHub's PR head may take to reach a pushed tip: 10 x 2 s.
WAIT_TRIES = 10
WAIT_SECONDS = 2.0

STRATEGIES = ("--squash", "--merge", "--rebase", "-s", "-m", "-r")
# The merged branch's deletion is the repo's `delete_branch_on_merge`, which
# retargets PRs stacked on it; deleting it here would close them.
DELETE = ("--delete-branch", "-d")


class Refused(Exception):
    """Why the PR was not merged."""


@dataclass(frozen=True)
class Pr:
    number: str
    state: str
    base: str
    # The head commit GitHub has recorded, which lags a push.
    head: str
    branch: str
    # From a fork: its branch is not on `origin`.
    fork: bool


def _run(argv: Sequence[str]) -> tuple[int, str]:
    done = subprocess.run(  # noqa: S603
        list(argv), check=False, stdout=subprocess.PIPE, text=True
    )
    return done.returncode, done.stdout


def _gh(run: Run, *args: str) -> str:
    code, out = run(["gh", *args])
    if code != 0:
        raise Refused(f"`gh {' '.join(args)}` exited {code}")
    return out


def view(run: Run, number: str) -> Pr:
    fields = "state,baseRefName,headRefOid,headRefName,isCrossRepository"
    raw = json.loads(_gh(run, "pr", "view", number, "--json", fields))
    return Pr(
        number,
        raw["state"],
        raw["baseRefName"],
        raw["headRefOid"],
        raw["headRefName"],
        raw["isCrossRepository"],
    )


def server_tip(run: Run, branch: str) -> str:
    """The branch's commit on `origin`, current as soon as a push returns."""

    code, out = run(["git", "ls-remote", "origin", f"refs/heads/{branch}"])
    sha = out.split()[0] if code == 0 and out.strip() else ""
    if not sha:
        raise Refused(f"`origin` has no branch {branch}")
    return sha


def local_tip(run: Run, branch: str) -> str | None:
    """The local branch's commit, or None where this clone lacks it."""

    code, out = run(
        ["git", "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"]
    )
    return out.strip() if code == 0 and out.strip() else None


def behind_by(run: Run, base: str, sha: str) -> int:
    out = _gh(
        run,
        "api",
        f"repos/{{owner}}/{{repo}}/compare/{quote(base, safe='')}...{sha}",
        "--jq",
        ".behind_by",
    )
    return int(out.strip())


def await_head(run: Run, pr: Pr, tip: str, sleep: Sleep) -> None:
    """Returns once GitHub's PR head is `tip`, the commit that was checked."""

    for _ in range(WAIT_TRIES):
        if pr.head == tip:
            return
        sleep(WAIT_SECONDS)
        pr = view(run, pr.number)
    if pr.head != tip:
        raise Refused(
            f"GitHub still records PR #{pr.number} at {pr.head[:7]}, not the "
            f"pushed {tip[:7]}, after {WAIT_TRIES * WAIT_SECONDS:.0f} s; "
            "merge again shortly"
        )


def merge(run: Run, number: str, flags: Sequence[str], sleep: Sleep) -> int:
    if not number.isdigit():
        raise Refused(f"expected a PR number, got {number!r}")
    if any(f in DELETE for f in flags):
        raise Refused(
            "drop --delete-branch: the repo's delete_branch_on_merge deletes "
            "the branch after GitHub retargets PRs stacked on it"
        )
    pr = view(run, number)
    if pr.state != "OPEN":
        raise Refused(f"PR #{number} is {pr.state.lower()}, not open")
    tip = pr.head if pr.fork else server_tip(run, pr.branch)
    local = None if pr.fork else local_tip(run, pr.branch)
    if local is not None and local != tip:
        raise Refused(
            f"{pr.branch} is at {local[:7]} here but {tip[:7]} on origin: "
            "push or pull it so they match, then merge again"
        )
    behind = behind_by(run, pr.base, tip)
    if behind > 0:
        raise Refused(
            f"PR #{number} is {behind} commit{'s' if behind != 1 else ''} "
            f"behind {pr.base}: its checks never ran on what merging would "
            f"produce. Rebase it onto origin/{pr.base}, push (the pre-push "
            "hook reruns the checks), then merge again."
        )
    await_head(run, pr, tip, sleep)
    strategy = [] if any(f in STRATEGIES for f in flags) else ["--squash"]
    code, out = run(
        [
            "gh",
            "pr",
            "merge",
            number,
            *strategy,
            "--match-head-commit",
            tip,
            *flags,
        ]
    )
    sys.stdout.write(out)
    return code


def main(
    argv: Sequence[str], run: Run = _run, sleep: Sleep = time.sleep
) -> int:
    if not argv:
        sys.stderr.write("usage: merge_pr.py <number> [gh pr merge flags]\n")
        return 2
    try:
        return merge(run, argv[0], argv[1:], sleep)
    except Refused as e:
        sys.stderr.write(f"merge_pr: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
