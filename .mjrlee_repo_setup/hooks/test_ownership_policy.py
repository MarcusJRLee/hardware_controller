"""What a repo declares about test ownership: its config file and markers.

`.mjrlee_repo_setup/test_ownership.toml` is the repo's own and may be absent.
Every table is optional; unknown tables and keys are errors:

    # Xcode keeps an app's tests in a sibling target. Sources under `source`
    # count as tested by a same-stem test anywhere under `tests`.
    [[test_root]]
    source = "ios/App/"
    tests = "ios/AppTests/"

    # `*` matches across `/`; a trailing `/` covers a whole directory.
    [[exempt]]
    path = "web/src/testing/"
    kind = "test support"
    reason = "Mocks and builders the tests import."  # Optional.

Header markers sit in a source's first lines, after any comment prefix:

- `Test exemption: <kind>.`, optionally followed by detail, exempts the file.
  A kind is one of `test_conventions.KINDS`.
- `Tested by: <repo-relative test path>.`, one line per test, names tests
  elsewhere that cover the file, so the claim moves with the file.
"""

from __future__ import annotations

import re
import tomllib
from collections.abc import Mapping
from dataclasses import dataclass
from itertools import islice
from pathlib import Path, PurePosixPath
from typing import Final, TypeGuard

from test_conventions import KINDS, Kind, TestRoot, matches

CONFIG: Final = PurePosixPath(".mjrlee_repo_setup/test_ownership.toml")
HEADER_LINES: Final = 15
_PREFIX: Final = r"^\s*(?:#|//|/\*+|\*|--)?\s*"
_MARKER: Final = re.compile(_PREFIX + r"Test exemption:\s*(?P<kind>[^.]*)\.?")
# A path never ends in `.`, so the sentence's period is never part of it.
_TESTED_BY: Final = re.compile(
    _PREFIX + r"Tested by:\s*(?P<test>\S+?)\.?\s*(?:\*/)?\s*$"
)
# The kit replaced this table with `Tested by:` header lines.
_MOVED_TABLES: Final[Mapping[str, str]] = {
    "owner": (
        "`[[owner]]` became `Tested by: <test>.` header lines; run the"
        " mjrlee-repo-setup skill's scripts/owners_to_markers.py on this repo"
    ),
}


@dataclass(frozen=True)
class Exemption:
    path: str
    kind: Kind
    reason: str | None

    def covers(self, rel: PurePosixPath) -> bool:
        return matches(self.path, rel)


@dataclass(frozen=True)
class Policy:
    roots: tuple[TestRoot, ...] = ()
    exemptions: tuple[Exemption, ...] = ()
    errors: tuple[str, ...] = ()


@dataclass(frozen=True)
class MarkerError:
    text: str


@dataclass(frozen=True)
class Header:
    """What a source's header markers declare."""

    kind: Kind | MarkerError | None = None
    tests: tuple[PurePosixPath, ...] = ()


@dataclass(frozen=True)
class _Table:
    required: frozenset[str]
    optional: frozenset[str] = frozenset()


_TABLES: Final[Mapping[str, _Table]] = {
    "test_root": _Table(frozenset({"source", "tests"})),
    "exempt": _Table(frozenset({"path", "kind"}), frozenset({"reason"})),
}


def is_kind(text: str) -> TypeGuard[Kind]:
    return text in KINDS


def unknown_kind(text: str) -> str:
    return f'unknown kind "{text}"; use one of: {", ".join(KINDS)}'


def read_header(path: Path) -> Header:
    """The markers in the file's first lines; empty when it is unreadable."""

    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            head = list(islice(handle, HEADER_LINES))
    except OSError:
        return Header()
    kind: Kind | MarkerError | None = None
    for line in head:
        found = _MARKER.match(line)
        if found is not None and kind is None:
            text = found.group("kind").strip()
            kind = text if is_kind(text) else MarkerError(unknown_kind(text))
    tests = tuple(
        PurePosixPath(found.group("test"))
        for line in head
        if (found := _TESTED_BY.match(line)) is not None
    )
    return Header(kind, tests)


def _text(value: object) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def _texts(value: object) -> tuple[str, ...] | None:
    items = value if isinstance(value, list) else []
    texts = tuple(text for item in items if (text := _text(item)) is not None)
    return texts if texts and len(texts) == len(items) else None


def _directory(value: str | None) -> str | None:
    return value if value is not None and value.endswith("/") else None


def _entries(
    document: Mapping[str, object], table: str, errors: list[str]
) -> list[Mapping[str, object]]:
    raw = document.get(table, [])
    if not isinstance(raw, list):
        errors.append(f"{CONFIG}: `{table}` must be an array of tables")
        return []
    schema = _TABLES[table]
    entries: list[Mapping[str, object]] = []
    for index, entry in enumerate(raw):
        where = f"{CONFIG}: {table}[{index}]"
        if not isinstance(entry, dict):
            errors.append(f"{where} must be a table")
            continue
        keys = {str(key) for key in entry}
        missing = sorted(schema.required - keys)
        unknown = sorted(keys - schema.required - schema.optional)
        if missing or unknown:
            errors.extend(f"{where} needs `{key}`" for key in missing)
            errors.extend(f"{where} has unknown key `{key}`" for key in unknown)
            continue
        entries.append({str(key): value for key, value in entry.items()})
    return entries


def parse_policy(document: Mapping[str, object]) -> Policy:
    errors = [
        f"{CONFIG}: {_MOVED_TABLES[key]}"
        if key in _MOVED_TABLES
        else f"{CONFIG}: unknown table `{key}`"
        for key in sorted(set(document) - set(_TABLES))
    ]
    roots: list[TestRoot] = []
    for index, entry in enumerate(_entries(document, "test_root", errors)):
        source = _directory(_text(entry["source"]))
        tests = _directory(_text(entry["tests"]))
        if source is None or tests is None:
            errors.append(
                f"{CONFIG}: test_root[{index}] `source` and `tests` must be"
                " directories ending in `/`"
            )
        else:
            roots.append(TestRoot(source, tests))
    exemptions: list[Exemption] = []
    for index, entry in enumerate(_entries(document, "exempt", errors)):
        path = _text(entry["path"])
        kind = _text(entry["kind"]) or ""
        reason = entry.get("reason")
        if path is None:
            errors.append(f"{CONFIG}: exempt[{index}] needs a `path`")
        elif not is_kind(kind):
            errors.append(f"{CONFIG}: exempt {path} has {unknown_kind(kind)}")
        elif reason is not None and _text(reason) is None:
            errors.append(f"{CONFIG}: exempt {path} has an empty `reason`")
        else:
            exemptions.append(Exemption(path, kind, _text(reason)))
    return Policy(tuple(roots), tuple(exemptions), tuple(errors))


def load_policy(root: Path) -> Policy:
    """Read the repo's declarations; an absent file declares none."""

    path = root / CONFIG
    if not path.is_file():
        return Policy()
    try:
        document = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as error:
        return Policy(errors=(f"{CONFIG}: {error}",))
    return parse_policy(document)
