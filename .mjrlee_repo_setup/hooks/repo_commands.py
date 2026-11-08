"""The repo's own commands for steps the kit drives, from `repo.toml`.

`.mjrlee_repo_setup/repo.toml` belongs to the repo, never the kit, and is
optional; a repo needs it only where its workflow differs from the defaults:

    [checkout]
    # Run in order from a new checkout's root to make it ready to build, test,
    # and push. Default: the lockfile's frozen install, else nothing.
    setup = [["pnpm", "install", "--frozen-lockfile"], ["pnpm", "setup:local"]]

    [replace]
    # Agents run the value instead of the command the key names; guard_git.py
    # denies the key's command.
    "gh pr merge" = "pnpm pr:merge <number>"

Check it from the repo root (exit 1 on an error):

    uv run --no-project python .mjrlee_repo_setup/hooks/repo_commands.py
"""

from __future__ import annotations

import re
import sys
import tomllib
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Final

CONFIG: Final = PurePosixPath(".mjrlee_repo_setup/repo.toml")
# Lockfile → frozen install; the first match wins.
INSTALLS: Final = (
    ("pnpm-lock.yaml", ("pnpm", "install", "--frozen-lockfile")),
    ("bun.lock", ("bun", "install", "--frozen-lockfile")),
    ("package-lock.json", ("npm", "ci")),
)
_TABLES: Final = {"checkout": frozenset({"setup"}), "replace": None}
_WORD: Final = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]*")

Argv = tuple[str, ...]


class RepoCommandsError(ValueError):
    """`repo.toml` is malformed; the message names the field."""


@dataclass(frozen=True)
class Replacement:
    """A command agents must not run, and what they run instead."""

    words: tuple[str, ...]
    instead: str

    @property
    def pattern(self) -> re.Pattern[str]:
        # Textual, like guard_git's bypasses: whole words, any whitespace.
        body = r"\s+".join(re.escape(w) for w in self.words)
        return re.compile(rf"(?<![\w./-]){body}(?![\w-])")


@dataclass(frozen=True)
class RepoCommands:
    setup: tuple[Argv, ...]
    replacements: tuple[Replacement, ...]

    def replacement_for(self, command: str) -> Replacement | None:
        return next(
            (r for r in self.replacements if r.pattern.search(command)), None
        )


def default_setup(root: Path) -> tuple[Argv, ...]:
    return next(
        ((argv,) for lock, argv in INSTALLS if (root / lock).is_file()), ()
    )


def _argv_list(value: object) -> tuple[Argv, ...]:
    where = f"{CONFIG}: checkout.setup"
    if not isinstance(value, list):
        raise RepoCommandsError(f"{where} must be a list of argv lists")
    steps: list[Argv] = []
    for n, step in enumerate(value):
        items: Sequence[object] = step if isinstance(step, list) else ()
        argv = tuple(a for a in items if isinstance(a, str) and a)
        if not argv or len(argv) != len(items):
            msg = f"{where}[{n}] must be a non-empty list of non-empty strings"
            raise RepoCommandsError(msg)
        steps.append(argv)
    return tuple(steps)


def _replacements(value: Mapping[str, object]) -> tuple[Replacement, ...]:
    found: list[Replacement] = []
    for key, instead in value.items():
        words = tuple(key.split())
        if len(words) < 2 or not all(_WORD.fullmatch(w) for w in words):
            msg = f"{CONFIG}: replace key `{key}` must be a command of 2+ words"
            raise RepoCommandsError(msg)
        if not isinstance(instead, str) or not instead.strip():
            msg = f"{CONFIG}: replace.`{key}` must name the command to run"
            raise RepoCommandsError(msg)
        found.append(Replacement(words, instead.strip()))
    return tuple(found)


def _check_keys(document: Mapping[str, object]) -> None:
    for table, value in document.items():
        if table not in _TABLES:
            raise RepoCommandsError(f"{CONFIG}: unknown table `{table}`")
        if not isinstance(value, dict):
            raise RepoCommandsError(f"{CONFIG}: `{table}` must be a table")
        allowed = _TABLES[table]
        keys = {key for key in value if isinstance(key, str)}
        unknown = sorted(keys - allowed) if allowed is not None else []
        if unknown:
            raise RepoCommandsError(
                f"{CONFIG}: unknown key `{table}.{unknown[0]}`"
            )


def load(root: Path) -> RepoCommands:
    """Read `root`'s commands; an absent file or key means the default."""

    path = root / CONFIG
    if not path.is_file():
        return RepoCommands(default_setup(root), ())
    try:
        document = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as error:
        raise RepoCommandsError(f"{CONFIG}: {error}") from error
    _check_keys(document)
    checkout = document.get("checkout", {})
    replace = document.get("replace", {})
    setup = (
        _argv_list(checkout["setup"])
        if "setup" in checkout
        else default_setup(root)
    )
    return RepoCommands(setup, _replacements(replace))


def main() -> int:
    try:
        load(Path.cwd())
    except RepoCommandsError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
