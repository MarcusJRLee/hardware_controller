"""PreToolUse hook: block agent shell commands that bypass the kit's git hooks.

The [Git] rules run as git hooks (`push_rules.py`, `worktree_rules.py`), where
git supplies the real refs and paths, so no shell parsing is needed there. This
hook only denies, by plain text match, the few ways to switch those hooks off;
merging a PR through GitHub's API, which would skip the repo's merge command;
renaming or deleting the default branch locally (`default_branch_rule.py`);
and the commands `repo.toml` (`repo_config.py`) `[replace]`s, such as
`gh pr merge` where the repo merges through its own script. Where `repo.toml`
declares quiet hours, it also denies commits, pushes, and GitHub writes inside
them, and hand-set commit dates at any time (`quiet_commands.py`). Blocks by printing
an explicit JSON deny decision, which Claude Code and Codex both honor.
"""

from __future__ import annotations

import re
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Final

import git_queries
from default_branch_rule import find_default_branch_change
from hook_event import deny_output, parse_event
from quiet_commands import date_override, recorded_write
from quiet_hours_rule import DATED_HINT, now_blocked
from repo_config import CONFIG, RepoConfig, RepoConfigError, load

# (pattern, what it does). Matching is textual, so a commit message or PR body
# that merely mentions one is caught too; BYPASS_HINT says how to pass it.
BYPASSES: Final = (
    (
        re.compile(r"\bgit\b[^\n;&|]*\s--no-verify\b"),
        "`--no-verify` skips git hooks",
    ),
    (
        re.compile(r"core\.hooksPath", re.IGNORECASE),
        "a `core.hooksPath` override skips git hooks",
    ),
    (
        re.compile(r"\bLEFTHOOK=(?:0|false|off)\b", re.IGNORECASE),
        "`LEFTHOOK=0` disables lefthook",
    ),
    (
        re.compile(r"\bLEFTHOOK_(?:EXCLUDE|SKIP)\b"),
        "`LEFTHOOK_EXCLUDE` skips lefthook jobs",
    ),
    (
        re.compile(r"\blefthook\s+uninstall\b"),
        "`lefthook uninstall` removes the git hooks",
    ),
    (
        re.compile(r"\bworktree\s+add\b[^\n;&|]*--no-checkout\b"),
        "`--no-checkout` skips the worktree location check",
    ),
)
BYPASS_HINT: Final = (
    "The kit's git hooks enforce the [Git] rules in AGENTS.md. If the user "
    "explicitly wants this, ask them to run it themselves; if this is only "
    "text, pass it from a file (`git commit -F`, `gh pr create --body-file`)."
)


def find_bypass(command: str) -> str | None:
    """Return what the first hook bypass in `command` does, or None."""

    return next(
        (why for pattern, why in BYPASSES if pattern.search(command)), None
    )


# A call to GitHub's API: `gh api` (any flags between) or its URL, as curl
# would use.
GITHUB_API: Final = re.compile(r"\bgh\b[^\n;&|]*?\sapi\b|\bapi\.github\.com\b")
# (pattern, what it calls). Every method on the REST endpoint is denied:
# telling a GET from a PUT means parsing `-X`, `--method=`, and the implicit
# POST of `-f`, which is where a bypass would hide.
API_MERGES: Final = (
    (
        re.compile(r"\bpulls/[^/\s\"']+/merge(?![\w-])"),
        "REST `pulls/<n>/merge`",
    ),
    (
        re.compile(r"\b(mergePullRequest|enablePullRequestAutoMerge)\b"),
        "GraphQL `{0}`",
    ),
)
MERGE: Final = "gh pr merge"


def _config(cwd: Path) -> RepoConfig | None:
    """The repo's `repo.toml`, or None outside a repo or when malformed.

    A malformed file denies nothing here; `setup_checkout.py` and
    `verify_repo_kit.py` report it.
    """

    root = git_queries.repo_root(cwd)
    if root is None:
        return None
    try:
        return load(root)
    except RepoConfigError:
        return None


def find_api_merge(cwd: Path, command: str) -> str | None:
    """Return why `command` is denied for merging through the API, or None.

    Denied in every repo, not only where `[replace]` names a merge command:
    `gh pr merge` or the replacement covers every API merge, and the rule
    never has to recognize which `[replace]` key is a merge.
    """

    if not GITHUB_API.search(command):
        return None
    found = next(
        (
            what.format(match[0])
            for pattern, what in API_MERGES
            if (match := pattern.search(command))
        ),
        None,
    )
    if found is None:
        return None
    config = _config(cwd)
    replacement = config.replacement_for(MERGE) if config else None
    merge = replacement.instead if replacement else f"{MERGE} <n>"
    return (
        f"Blocked: {found} merges a PR through GitHub's API, skipping the "
        f"repo's merge command. Merge with `{merge}`; to check whether a PR "
        "merged, run `gh pr view <n> --json state,mergedAt`. If this is only "
        "text, pass it from a file."
    )


def find_quiet(cwd: Path, command: str, now: datetime) -> str | None:
    """Return why quiet hours deny `command` at `now`, or None."""

    config = _config(cwd)
    hours = config.quiet_hours if config else None
    if config is None or hours is None or not hours.windows:
        return None
    if override := date_override(command):
        return f"Blocked: {override}. {DATED_HINT}."
    # A repo's replacement for a write, such as its own merge script, writes.
    write = recorded_write(command) or next(
        (
            f"`{r.instead}` runs `{' '.join(r.words)}`"
            for r in config.replacements
            if recorded_write(" ".join(r.words))
            and r.instead_pattern.search(command)
        ),
        None,
    )
    blocked = now_blocked(hours, now, "run it") if write else None
    if blocked is None:
        return None
    return (
        f"{blocked}. {write}. Edit and test locally meanwhile; if this is only"
        " text, pass it from a file."
    )


def find_replaced(cwd: Path, command: str) -> str | None:
    """Return why `command` is denied in favor of the repo's own, or None."""

    config = _config(cwd)
    replacement = config.replacement_for(command) if config else None
    if replacement is None:
        return None
    return (
        f"Blocked: this repo runs `{replacement.instead}` instead of "
        f"`{' '.join(replacement.words)}` ({CONFIG}). If this is only "
        "text, pass it from a file."
    )


def main() -> int:
    event = parse_event(sys.stdin.read())
    command = event.command or ""
    why = find_bypass(command)
    if why is not None:
        print(deny_output(event, f"Blocked: {why}. {BYPASS_HINT}"))
        return 0
    denied = (
        find_quiet(event.cwd, command, datetime.now(UTC))
        or find_api_merge(event.cwd, command)
        or find_default_branch_change(event.cwd, command)
        or find_replaced(event.cwd, command)
    )
    if denied is not None:
        print(deny_output(event, denied))
    return 0


if __name__ == "__main__":
    sys.exit(main())
