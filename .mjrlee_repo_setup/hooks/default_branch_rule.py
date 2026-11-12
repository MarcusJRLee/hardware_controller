"""Deny renaming or deleting the default branch in a local checkout.

The main checkout stays on the default branch, and every worktree and roadmap
claim is cut from it, so `git branch -m feature` run there renames it out from
under them. No git hook sees a local branch rename or delete, so `guard_git.py`
applies this rule to agent shell commands: it splits them into shell words and
reads `git branch` the way git parses it. Deleting the branch on origin is
`push_rules.py`'s, which sees the real refs.
"""

from __future__ import annotations

import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Final

import git_queries

SEPARATORS: Final = ";&|()\n"
# Words that run the command after them, with their own options.
WRAPPERS: Final = frozenset(
    {"command", "env", "exec", "nice", "nohup", "sudo", "time"}
)
# Git's global options that take the next word as their value.
GIT_VALUE_OPTIONS: Final = frozenset(
    {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"}
)
# `git branch` options that take the next word as their value.
BRANCH_VALUE_OPTIONS: Final = frozenset(
    {
        "-u",
        "--set-upstream-to",
        "--contains",
        "--no-contains",
        "--points-at",
        "--sort",
        "--format",
    }
)


def _words(command: str) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=SEPARATORS)
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = ""
    return list(lexer)


def segments(command: str) -> list[list[str]]:
    """Split `command` into simple commands of shell words.

    Quotes are honored, so `echo "a; b"` stays one word. Unbalanced quotes
    are dropped and the text split again, which errs toward denying.
    """

    try:
        words = _words(command)
    except ValueError:
        words = _words(command.replace('"', " ").replace("'", " "))
    found: list[list[str]] = [[]]
    for word in words:
        if word and set(word) <= set(SEPARATORS):
            found.append([])
        else:
            found[-1].append(word)
    return [s for s in found if s]


@dataclass(frozen=True)
class GitCall:
    """A `git` invocation: where it runs and its subcommand's words."""

    cwd: Path
    subcommand: str
    args: tuple[str, ...]


def git_call(cwd: Path, words: list[str]) -> GitCall | None:
    """Parse one simple command as a git call, or None if it is not one."""

    rest = iter(words)
    word = next(rest, None)
    while word is not None and (
        "=" in word.split("/")[0] or word in WRAPPERS or word.startswith("-")
    ):
        word = next(rest, None)
    if word is None or Path(word).name != "git":
        return None
    where = cwd
    for word in rest:
        name = word.split("=", 1)[0]
        if not word.startswith("-"):
            return GitCall(where, word, tuple(rest))
        value = next(rest, "") if word in GIT_VALUE_OPTIONS else None
        if name == "-C" and value is not None:
            where = where / value
    return None


@dataclass(frozen=True)
class BranchCall:
    delete: bool
    move: bool
    remote: bool
    names: tuple[str, ...]


def _long(word: str, option: str) -> bool:
    """Git accepts any unambiguous prefix of a long option, such as `--del`."""

    name = word[2:].split("=", 1)[0]
    return len(name) >= 2 and option.startswith(name)


def parse_branch(args: tuple[str, ...]) -> BranchCall:
    delete = move = remote = False
    names: list[str] = []
    words = iter(args)
    for word in words:
        if word == "--":
            names.extend(words)
        elif word.startswith("--"):
            delete |= _long(word, "delete")
            move |= _long(word, "move")
            remote |= _long(word, "remotes")
            if word in BRANCH_VALUE_OPTIONS:
                next(words, None)
        elif word.startswith("-") and len(word) > 1:
            # `-u` takes the rest of the cluster as its value, else the next
            # word, so only the letters before it are flags.
            cluster, u, value = word[1:].partition("u")
            delete |= bool(set(cluster) & {"d", "D"})
            move |= bool(set(cluster) & {"m", "M"})
            remote |= "r" in cluster
            if u and not value:
                next(words, None)
        else:
            names.append(word)
    return BranchCall(delete, move, remote, tuple(names))


def _denial(verb: str, default: str, alternative: str) -> str:
    return (
        f"Blocked: this {verb} `{default}`, the default branch that the main "
        f"checkout stays on and every worktree is cut from. {alternative} "
        "Changing the default branch is the user's call, made on GitHub. If "
        "this is only text, pass it from a file."
    )


def find_default_branch_change(cwd: Path, command: str) -> str | None:
    """Return why `command` renames or deletes the default branch, or None.

    The default comes from `git_queries.default_branch` (`origin/HEAD`) in the
    directory the call runs in; with it unset, nothing is denied.
    """

    for words in segments(command):
        call = git_call(cwd, words)
        if call is None:
            continue
        default = git_queries.default_branch(call.cwd)
        if default is None:
            continue
        delete_alternative = "Delete another branch by name instead."
        if call.subcommand == "update-ref":
            if "-d" in call.args and f"refs/heads/{default}" in call.args:
                return _denial("deletes", default, delete_alternative)
            continue
        if call.subcommand != "branch":
            continue
        branch = parse_branch(call.args)
        if branch.delete and not branch.remote and default in branch.names:
            return _denial("deletes", default, delete_alternative)
        if not branch.move or not branch.names:
            continue
        # One name renames the current branch; two rename the first.
        old = (
            branch.names[0]
            if len(branch.names) > 1
            else git_queries.current_branch(call.cwd)
        )
        new = branch.names[-1]
        rename_alternative = (
            "To work under a new name, branch from it with "
            "`git switch -c <name>`."
        )
        if old == default:
            return _denial("renames", default, rename_alternative)
        if new == default:
            return _denial("overwrites", default, rename_alternative)
    return None
