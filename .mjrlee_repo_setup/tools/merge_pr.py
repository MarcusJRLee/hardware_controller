"""Merge a PR only when its branch holds its base's latest commit.

    uv run --no-project python .mjrlee_repo_setup/tools/merge_pr.py <number>
    ... merge_pr.py <number> --merge     # Any other `gh pr merge` flags pass on.

GitHub calls a PR mergeable when its diff applies, not when its checks ran on
the result. Two PRs that each pass alone can still break the base together, so
this refuses a PR whose branch is behind its base: rebase it, push (the
pre-push hook runs the checks on the combined code), and merge again. It
squash-merges unless told otherwise, with `--match-head-commit`, so a push
between the check and the merge fails the merge instead of landing code the
check never saw.

A repo adopts it in `.mjrlee_repo_setup/repo.toml`, which makes the kit's
`guard_git.py` deny a plain `gh pr merge`:

    [replace]
    "gh pr merge" = "uv run --no-project python .mjrlee_repo_setup/tools/merge_pr.py <number>"
"""

from __future__ import annotations

import json
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from urllib.parse import quote

# Runs argv and returns its exit code and stdout; stderr passes through.
Run = Callable[[Sequence[str]], tuple[int, str]]

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
    head: str


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
    raw = json.loads(
        _gh(run, "pr", "view", number, "--json", "state,baseRefName,headRefOid")
    )
    return Pr(number, raw["state"], raw["baseRefName"], raw["headRefOid"])


def behind_by(run: Run, pr: Pr) -> int:
    base = quote(pr.base, safe="")
    out = _gh(
        run,
        "api",
        f"repos/{{owner}}/{{repo}}/compare/{base}...{pr.head}",
        "--jq",
        ".behind_by",
    )
    return int(out.strip())


def merge(run: Run, number: str, flags: Sequence[str]) -> int:
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
    behind = behind_by(run, pr)
    if behind > 0:
        raise Refused(
            f"PR #{number} is {behind} commit{'s' if behind != 1 else ''} "
            f"behind {pr.base}: its checks never ran on what merging would "
            f"produce. Rebase it onto origin/{pr.base}, push (the pre-push "
            "hook reruns the checks), then merge again. Just pushed? GitHub "
            "can report the old head for a few seconds; retry."
        )
    strategy = [] if any(f in STRATEGIES for f in flags) else ["--squash"]
    code, out = run(
        [
            "gh",
            "pr",
            "merge",
            number,
            *strategy,
            "--match-head-commit",
            pr.head,
            *flags,
        ]
    )
    sys.stdout.write(out)
    return code


def main(argv: Sequence[str], run: Run = _run) -> int:
    if not argv:
        sys.stderr.write("usage: merge_pr.py <number> [gh pr merge flags]\n")
        return 2
    try:
        return merge(run, argv[0], argv[1:])
    except Refused as e:
        sys.stderr.write(f"merge_pr: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
