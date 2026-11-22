"""Split shell text into the words of each simple command, for PreToolUse guards.

This is shell words, not a full shell parse: `$(…)`, backticks, and `bash -c`
bodies stay single words, so a guard sees only the top-level commands. Heredoc
bodies are dropped as data, which also keeps an apostrophe in a PR body from
unbalancing the quotes of the command around it. Line continuations join, and
newlines, `;`, `&`, `|`, and parentheses separate commands. Raises ValueError on
quotes the shell itself could not read. `target_dirs` names the directories a
command's repo rules must be read from.
"""

from __future__ import annotations

import os
import re
import shlex
from collections.abc import Iterator, Sequence
from pathlib import Path
from typing import Final

# Characters that separate simple commands; shlex groups a run of them into one
# token, such as `&&` or `)\n`.
_OPERATORS: Final = ";&|()\n"
# `<<WORD`, `<<-'WORD'`, or `<<"WORD"`; `<<<` is a here-string, not a heredoc.
_HEREDOC: Final = re.compile(r"(?<!<)<<(-?)\s*(['\"]?)([\w.-]+)\2")
# Words that may precede the command word without being it.
_WRAPPERS: Final = frozenset(
    {"sudo", "env", "command", "exec", "time", "nohup"}
)
_ASSIGNMENT: Final = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
# Git's global options that take the next word as their value.
GIT_VALUE_OPTIONS: Final = frozenset(
    {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"}
)


def strip_heredocs(command: str) -> str:
    """Return `command` without heredoc bodies, keeping their `<<WORD` lines."""

    kept: list[str] = []
    pending: list[tuple[bool, str]] = []
    for line in command.split("\n"):
        if pending:
            dash, word = pending[0]
            if (line.lstrip("\t") if dash else line) == word:
                pending.pop(0)
            continue
        kept.append(line)
        pending = [(m[1] == "-", m[3]) for m in _HEREDOC.finditer(line)]
    return "\n".join(kept)


def simple_commands(command: str) -> Iterator[list[str]]:
    """Yield the words of each simple command in `command`, empty ones skipped."""

    lexer = shlex.shlex(
        strip_heredocs(command).replace("\\\n", " "),
        posix=True,
        punctuation_chars=_OPERATORS,
    )
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = ""
    current: list[str] = []
    for token in lexer:
        if set(token) <= set(_OPERATORS):
            if current:
                yield current
            current = []
        else:
            current.append(token)
    if current:
        yield current


def command_args(words: Sequence[str], name: str) -> list[str] | None:
    """Return the arguments when a simple command runs `name`, else None.

    Assignments (`X=1`), wrappers (`sudo`, `env`), and their options are
    skipped; a path such as `/usr/bin/gh` counts as its basename.
    """

    for index, word in enumerate(words):
        if _ASSIGNMENT.match(word) or word in _WRAPPERS or word[:1] == "-":
            continue
        if word.rsplit("/", 1)[-1] == name:
            return list(words[index + 1 :])
        return None
    return None


def _resolve(where: Path, word: str) -> Path:
    return where / os.path.expandvars(os.path.expanduser(word))


def target_dirs(cwd: Path, command: str) -> tuple[Path, ...]:
    """Return `cwd` and each directory `command` moves to or points git at.

    `cd` and `pushd` carry to the commands after them and `git -C` applies to
    its own call, each resolved against the directory before it. A subshell's
    `cd` is kept past its `)`, and a `cd` that would fail is still followed:
    a guard then reads one directory too many, which errs toward denying.
    `cd -` and an unreadable command add nothing, leaving `cwd`.
    """

    found = [cwd]
    where = cwd
    try:
        commands = list(simple_commands(command))
    except ValueError:
        return (cwd,)
    for words in commands:
        moved = command_args(words, "cd")
        if moved is None:
            moved = command_args(words, "pushd")
        if moved is not None:
            dirs = [w for w in moved if w[:1] != "-" or w == "-"]
            if dirs[:1] == ["-"]:
                continue
            where = _resolve(where, dirs[0]) if dirs else Path.home()
            found.append(where)
            continue
        args = iter(command_args(words, "git") or [])
        at = where
        for option in args:
            if option[:1] != "-":
                break
            value = next(args, "") if option in GIT_VALUE_OPTIONS else None
            if option == "-C" and value:
                at = _resolve(at, value)
                found.append(at)
    return tuple(dict.fromkeys(found))
