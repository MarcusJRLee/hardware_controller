"""The repo's own settings for what the kit drives, from `repo.toml`.

`.mjrlee_repo_setup/repo.toml` belongs to the repo, never the kit. Every repo
has one, since `[launch]` and `[quiet_hours]` are required; the other tables
are needed only where the repo's workflow differs from the defaults:

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

    [quiet_hours]
    # Required, even as `windows = []`, which needs no `timezone`. Inside a window no commit is created
    # or pushed and agents make no GitHub writes (`quiet_hours.py`). Times are
    # wall-clock in `timezone`; `end` may be "24:00", and a window whose end
    # is not after its start runs past midnight from each of its `days`.
    timezone = "America/New_York"
    windows = [
      { days = ["mon", "tue", "wed", "thu", "fri"], start = "09:00", end = "17:00" },
    ]

Check it from the repo root (exit 1 on an error, an undeclared phase, or
undeclared quiet hours):

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

from quiet_hours import QuietHours, QuietHoursError, parse

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
    "quiet_hours": frozenset({"timezone", "windows"}),
}
PHASES: Final = ("pre_launch", "public")
_WORD: Final = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]*")

Argv = tuple[str, ...]


class RepoConfigError(ValueError):
    """`repo.toml` is malformed; the message names the field."""


def _words_pattern(words: Sequence[str]) -> re.Pattern[str]:
    # Textual, like guard_git's bypasses: whole words, any whitespace.
    body = r"\s+".join(re.escape(w) for w in words)
    return re.compile(rf"(?<![\w./-]){body}(?![\w-])")


@dataclass(frozen=True)
class Replacement:
    """A command agents must not run, and what they run instead."""

    words: tuple[str, ...]
    instead: str

    @property
    def pattern(self) -> re.Pattern[str]:
        return _words_pattern(self.words)

    @property
    def instead_pattern(self) -> re.Pattern[str]:
        """Match the replacement's own leading words, before any `<arg>`."""

        words = self.instead.split()
        cut = next((n for n, w in enumerate(words) if w.startswith("<")), None)
        return _words_pattern(words[:cut] or words)


@dataclass(frozen=True)
class RepoConfig:
    setup: tuple[Argv, ...]
    replacements: tuple[Replacement, ...]
    # None: undeclared, which verify and the push rule refuse.
    phase: str | None = None
    # None: undeclared, which verify refuses; hooks then block nothing, so a
    # kit update never stops a repo that has yet to answer.
    quiet_hours: QuietHours | None = None

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
QUIET_UNDECLARED: Final = (
    f"{CONFIG} must declare `[quiet_hours]` with `windows`"
    " (`windows = []` for none)"
)


def _quiet_hours(table: object) -> QuietHours | None:
    if table is None:
        return None
    try:
        return parse(table, str(CONFIG))
    except QuietHoursError as error:
        raise RepoConfigError(str(error)) from error


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
        quiet_hours=_quiet_hours(document.get("quiet_hours")),
    )


def main() -> int:
    try:
        config = load(Path.cwd())
    except RepoConfigError as error:
        print(error, file=sys.stderr)
        return 1
    missing = [
        message
        for message, absent in (
            (UNDECLARED, config.phase is None),
            (QUIET_UNDECLARED, config.quiet_hours is None),
        )
        if absent
    ]
    for message in missing:
        print(message, file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
