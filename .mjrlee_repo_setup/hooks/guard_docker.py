"""PreToolUse hook: block agent docker commands that create unlabeled resources.

An unlabeled container, image, volume, or network is one nobody can later
attribute or safely delete, so creation needs every key in docker_labels.KEYS.
`docker run --rm` is exempt: docker deletes it, and its anonymous volumes, on
exit. `--label-file` counts as labeled, since its contents are not visible
here. Compose stacks take their labels from compose files, which the
docker_labels gate checks, and scripts that call docker are caught by the
audit tool instead. Text inside quotes (`sh -c "docker run …"`) is not parsed.
"""

from __future__ import annotations

import re
import shlex
import sys
from collections.abc import Iterator, Sequence
from typing import Final

from docker_labels import GUIDANCE, label_problems
from hook_event import deny_output, parse_event

# Subcommand paths that create a labelable resource.
CREATORS: Final = frozenset(
    {
        ("run",),
        ("create",),
        ("container", "run"),
        ("container", "create"),
        ("build",),
        ("image", "build"),
        ("buildx", "build"),
        ("builder", "build"),
        ("volume", "create"),
        ("network", "create"),
    }
)
# Global options before the subcommand that consume the next token.
_GLOBAL_VALUE_OPTIONS: Final = frozenset(
    {"-c", "--context", "-H", "--host", "--config", "-l", "--log-level"}
)
_SEPARATORS: Final = frozenset({";", "&&", "||", "|", "&", "(", ")"})
# Words that may precede the command word without being it.
_WRAPPERS: Final = frozenset(
    {"sudo", "env", "command", "exec", "time", "nohup"}
)
_ASSIGNMENT: Final = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")


def _simple_commands(command: str) -> Iterator[list[str]]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    current: list[str] = []
    for token in lexer:
        if token in _SEPARATORS:
            yield current
            current = []
        else:
            current.append(token)
    yield current


def _docker_args(words: Sequence[str]) -> tuple[str, ...] | None:
    """Return the arguments after `docker` in one simple command, or None."""

    for index, word in enumerate(words):
        if _ASSIGNMENT.match(word) or word in _WRAPPERS or word[:1] == "-":
            continue
        if word.rsplit("/", 1)[-1] == "docker":
            return tuple(words[index + 1 :])
        return None
    return None


def _split_subcommand(args: Sequence[str]) -> tuple[tuple[str, ...], list[str]]:
    """Split docker arguments into the subcommand path and its options."""

    index = 0
    while index < len(args) and args[index].startswith("-"):
        index += 2 if args[index] in _GLOBAL_VALUE_OPTIONS else 1
    rest = list(args[index:])
    for path in sorted(CREATORS, key=len, reverse=True):
        if tuple(rest[: len(path)]) == path:
            return path, rest[len(path) :]
    return (), rest


def _labels(options: Sequence[str]) -> dict[str, str] | None:
    """Return labels set by `--label`/`-l`; None when a label file is used."""

    labels: dict[str, str] = {}
    for index, option in enumerate(options):
        if option == "--" or not option.startswith("-"):
            continue
        if option.startswith("--label-file"):
            return None
        if option in ("--label", "-l"):
            value = options[index + 1] if index + 1 < len(options) else ""
        elif option.startswith("--label="):
            value = option.removeprefix("--label=")
        else:
            continue
        key, _, text = value.partition("=")
        labels[key] = text
    return labels


def find_problem(command: str) -> str | None:
    """Return why `command` would create an unlabeled resource, or None."""

    try:
        commands = list(_simple_commands(command))
    except ValueError:
        return None  # Unbalanced quotes: the shell itself will refuse it.
    for words in commands:
        args = _docker_args(words)
        if args is None:
            continue
        path, options = _split_subcommand(args)
        if not path or (path[-1] == "run" and "--rm" in options):
            continue
        labels = _labels(options)
        if labels is None:
            continue
        problems = label_problems(labels)
        if problems:
            return f"`docker {' '.join(path)}` is {', '.join(problems)}"
    return None


def main() -> int:
    event = parse_event(sys.stdin.read())
    problem = find_problem(event.command or "")
    if problem is not None:
        reason = (
            f"Blocked: {problem}. {GUIDANCE}. Add e.g. --label "
            "mjrlee.owner=<repo/module> --label 'mjrlee.purpose=<why>' "
            "--label mjrlee.lifetime=ephemeral."
        )
        print(deny_output(event, reason))
    return 0


if __name__ == "__main__":
    sys.exit(main())
