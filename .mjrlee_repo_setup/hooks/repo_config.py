"""The repo's own settings for what the kit drives, from `repo.toml`.

`.mjrlee_repo_setup/repo.toml` belongs to the repo, never the kit. Every repo
has one, since `[launch]` is required; the other tables are needed only where
the repo's workflow differs from the defaults:

    [checkout]
    # Run in order from a new checkout's root to make it ready to build, test,
    # and push (`setup_checkout.py`). Default: the lockfile's frozen install,
    # else nothing.
    setup = [["pnpm", "install", "--frozen-lockfile"], ["pnpm", "setup:local"]]

    [replace]
    # Agents run the value instead of the command the key names; guard_git.py
    # denies the key's command.
    "gh pr merge" = "pnpm pr:merge <number>"

    [launch]
    # Required: every repo states its phase rather than inherit one.
    # `pre_launch`: tearing down and outages are fine. `public`: never
    # interrupt service; every pushed commit names its flag (`launch_rule.py`).
    phase = "public"

Check it from the repo root (exit 1 on an error or an undeclared phase):

    uv run --no-project python .mjrlee_repo_setup/hooks/repo_config.py
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
# Each table and its allowed keys; None allows any key.
_TABLES: Final[Mapping[str, frozenset[str] | None]] = {
    "checkout": frozenset({"setup"}),
    "replace": None,
    "launch": frozenset({"phase"}),
}
PHASES: Final = ("pre_launch", "public")
_WORD: Final = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]*")

Argv = tuple[str, ...]


class RepoConfigError(ValueError):
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
class RepoConfig:
    setup: tuple[Argv, ...]
    replacements: tuple[Replacement, ...]
    # None: undeclared, which verify and the push rule refuse.
    phase: str | None = None

    @property
    def public(self) -> bool:
        return self.phase == "public"

    def replacement_for(self, command: str) -> Replacement | None:
        return next(
            (r for r in self.replacements if r.pattern.search(command)), None
        )


def default_setup(root: Path) -> tuple[Argv, ...]:
    return next(
        ((argv,) for lock, argv in INSTALLS if (root / lock).is_file()), ()
    )


def _items(value: object) -> Sequence[object]:
    return value if isinstance(value, list) else ()


def _setup(value: object) -> tuple[Argv, ...]:
    where = f"{CONFIG}: checkout.setup"
    if not isinstance(value, list):
        raise RepoConfigError(f"{where} must be a list of argv lists")
    steps: list[Argv] = []
    for n, step in enumerate(value):
        items = _items(step)
        argv = tuple(a for a in items if isinstance(a, str) and a)
        if not argv or len(argv) != len(items):
            msg = f"{where}[{n}] must be a non-empty list of non-empty strings"
            raise RepoConfigError(msg)
        steps.append(argv)
    return tuple(steps)


def _replacements(table: Mapping[str, object]) -> tuple[Replacement, ...]:
    found: list[Replacement] = []
    for key, instead in table.items():
        words = tuple(key.split())
        if len(words) < 2 or not all(_WORD.fullmatch(w) for w in words):
            msg = f"{CONFIG}: replace key `{key}` must be a command of 2+ words"
            raise RepoConfigError(msg)
        if not isinstance(instead, str) or not instead.strip():
            msg = f"{CONFIG}: replace.`{key}` must name the command to run"
            raise RepoConfigError(msg)
        found.append(Replacement(words, instead.strip()))
    return tuple(found)


def _phase(table: object) -> str | None:
    if table is None:
        return None
    phase = table.get("phase") if isinstance(table, dict) else None
    if phase not in PHASES:
        msg = f"{CONFIG}: `launch.phase` must be one of {', '.join(PHASES)}"
        raise RepoConfigError(msg)
    return str(phase)


UNDECLARED: Final = (
    f'{CONFIG} must declare `[launch] phase = "pre_launch"` or `"public"`'
)


def _check_keys(document: Mapping[str, object]) -> None:
    for table, value in document.items():
        if table not in _TABLES:
            raise RepoConfigError(f"{CONFIG}: unknown table `{table}`")
        if not isinstance(value, dict):
            raise RepoConfigError(f"{CONFIG}: `{table}` must be a table")
        allowed = _TABLES[table]
        keys = {key for key in value if isinstance(key, str)}
        unknown = sorted(keys - allowed) if allowed is not None else []
        if unknown:
            msg = f"{CONFIG}: unknown key `{table}.{unknown[0]}`"
            raise RepoConfigError(msg)


def load(root: Path) -> RepoConfig:
    """Read `root`'s settings; an absent file, table, or key is the default."""

    path = root / CONFIG
    if not path.is_file():
        return RepoConfig(default_setup(root), ())
    try:
        document = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as error:
        raise RepoConfigError(f"{CONFIG}: {error}") from error
    _check_keys(document)
    checkout = document.get("checkout", {})
    return RepoConfig(
        setup=(
            _setup(checkout["setup"])
            if "setup" in checkout
            else default_setup(root)
        ),
        replacements=_replacements(document.get("replace", {})),
        phase=_phase(document.get("launch")),
    )


def main() -> int:
    try:
        config = load(Path.cwd())
    except RepoConfigError as error:
        print(error, file=sys.stderr)
        return 1
    if config.phase is None:
        print(UNDECLARED, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
