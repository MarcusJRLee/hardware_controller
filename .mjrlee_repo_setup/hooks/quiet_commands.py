"""Classify agent shell commands by the audit-visible trace they leave.

`guard_git.py` denies, inside quiet hours (`quiet_hours.py`), every command
that creates or publishes a dated git object or writes to GitHub, and at any
time in a repo with quiet hours, every override of a commit's dates. GitHub
commands are an allowlist of reads, so a new `gh` verb counts as a write until
listed here. Matching reads shell words, not a full shell parse: like the rest
of `guard_git.py`, it may deny a command that only mentions one.
"""

from __future__ import annotations

import re
import shlex
from collections.abc import Iterator, Sequence
from pathlib import PurePosixPath
from typing import Final

# Shell operators that start a new simple command.
_SEPARATORS: Final = re.compile(r"&&|\|\||[;|&\n()]")
# Git subcommands that create a commit object, dated now.
GIT_WRITES: Final = frozenset(
    {
        "am",
        "cherry-pick",
        "commit",
        "commit-tree",
        "merge",
        "pull",
        "push",
        "rebase",
        "revert",
    }
)
# Flags that make `git tag` create a dated tag object.
_ANNOTATED_TAG: Final = frozenset(
    {"-a", "-s", "-m", "-F", "--annotate", "--sign", "--message", "--file"}
)
# Global options that take a separate value: `git -C dir`, `gh -R repo`.
_GIT_VALUE_OPTIONS: Final = frozenset(
    {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
)
_GH_VALUE_OPTIONS: Final = frozenset({"-R", "--repo", "--hostname"})
# `gh` groups that never write to a repository's GitHub record.
GH_READ_GROUPS: Final = frozenset(
    {
        "alias",
        "auth",
        "browse",
        "completion",
        "config",
        "extension",
        "help",
        "search",
        "status",
        "version",
    }
)
# Verbs that only read GitHub or act locally, in any other group.
GH_READ_VERBS: Final = frozenset(
    {
        "checkout",
        "checks",
        "clone",
        "diff",
        "download",
        "list",
        "status",
        "view",
        "watch",
    }
)
_API_FIELDS: Final = re.compile(r"-[fF].*|--(?:field|raw-field|input)(?:=.*)?")
_API_METHOD: Final = re.compile(r"-X(.*)|--method(?:=(.*))?")
# Ways to set a commit's dates by hand.
_DATE_ENV: Final = re.compile(r"\bGIT_(?:AUTHOR|COMMITTER)_DATE\b")
_DATE_FLAGS: Final = {
    "commit": frozenset({"--date"}),
    "rebase": frozenset(
        {
            "--committer-date-is-author-date",
            "--ignore-date",
            "--reset-author-date",
        }
    ),
    "am": frozenset({"--committer-date-is-author-date", "--ignore-date"}),
}


def _words(command: str) -> Iterator[list[str]]:
    # `re.split` types its parts loosely; keep only the text ones.
    for segment in filter(None, map(str, _SEPARATORS.split(command))):
        try:
            words = shlex.split(segment)
        except ValueError:
            words = segment.split()
        if words:
            yield words


def _after(words: Sequence[str], tool: str) -> Iterator[list[str]]:
    """Yield the arguments after each `tool` word, global options dropped."""

    takes_value = _GIT_VALUE_OPTIONS if tool == "git" else _GH_VALUE_OPTIONS
    for n, word in enumerate(words):
        if PurePosixPath(word).name != tool:
            continue
        rest = list(words[n + 1 :])
        while rest and rest[0].startswith("-"):
            rest = rest[2:] if rest[0] in takes_value else rest[1:]
        if rest:
            yield rest


def _flag(args: Sequence[str], names: frozenset[str]) -> str | None:
    return next((a for a in args if a.split("=", 1)[0] in names), None)


def _git_write(args: Sequence[str]) -> str | None:
    sub = args[0]
    if sub in GIT_WRITES:
        return f"`git {sub}` creates or publishes a dated commit"
    if sub == "tag" and _flag(args[1:], _ANNOTATED_TAG):
        return "`git tag` with a message creates a dated tag"
    return None


def _api_write(args: Sequence[str]) -> bool:
    method: str | None = None
    fields = False
    for n, arg in enumerate(args):
        if match := _API_METHOD.fullmatch(arg):
            attached = [g for g in match.groups() if isinstance(g, str) and g]
            following = args[n + 1] if n + 1 < len(args) else ""
            method = attached[0] if attached else following
        fields = fields or bool(_API_FIELDS.fullmatch(arg))
    if "graphql" in args:
        return any("mutation" in a for a in args)
    if method is not None:
        return method.upper() != "GET"
    # `gh api` sends a POST once it has fields.
    return fields


def _gh_write(args: Sequence[str]) -> str | None:
    group = args[0]
    if group in GH_READ_GROUPS:
        return None
    if group == "api":
        return "`gh api` writes to GitHub" if _api_write(args[1:]) else None
    verb = next((a for a in args[1:] if not a.startswith("-")), None)
    if verb in GH_READ_VERBS:
        return None
    return f"`gh {' '.join(args[:2])}` writes to GitHub"


def recorded_write(command: str) -> str | None:
    """Return what the first audit-visible write in `command` does, or None."""

    for words in _words(command):
        for args in _after(words, "git"):
            if found := _git_write(args):
                return found
        for args in _after(words, "gh"):
            if found := _gh_write(args):
                return found
    return None


def date_override(command: str) -> str | None:
    """Return how `command` sets a commit's dates by hand, or None."""

    if match := _DATE_ENV.search(command):
        return f"`{match[0]}` sets a commit date by hand"
    for words in _words(command):
        for args in _after(words, "git"):
            names = _DATE_FLAGS.get(args[0], frozenset())
            if flag := _flag(args[1:], names):
                return f"`git {args[0]} {flag.split('=', 1)[0]}` changes a commit date"
    return None
