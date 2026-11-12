"""What a repo declares about test ownership: its config file and markers.

`.mjrlee_repo_setup/test_ownership.toml` is the repo's own and may be absent.
Every table is optional; unknown tables and keys are errors:

    # Xcode keeps an app's tests in a sibling target. Sources under `source`
    # count as tested by a same-stem test anywhere under `tests`.
    [[test_root]]
    source = "ios/App/"
    tests = "ios/AppTests/"

    # A test elsewhere owns this source's behavior.
    [[owner]]
    source = "web/src/pages/home_page.tsx"
    tests = ["web/src/prerender/render_site_test.tsx"]

    # `*` matches across `/`; a trailing `/` covers a whole directory.
    [[exempt]]
    path = "web/src/testing/"
    kind = "test support"
    reason = "Mocks and builders the tests import."  # Optional.

A header marker exempts one file: within its first lines, after any comment
prefix, the sentence `Test exemption: <kind>.`, optionally followed by detail.
A kind is one of `test_conventions.KINDS`.
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
_MARKER: Final = re.compile(
    r"^\s*(?:#|//|/\*+|\*|--)?\s*Test exemption:\s*(?P<kind>[^.]*)\.?"
)


@dataclass(frozen=True)
class Exemption:
    path: str
    kind: Kind
    reason: str | None

    def covers(self, rel: PurePosixPath) -> bool:
        return matches(self.path, rel)


@dataclass(frozen=True)
class Owner:
    source: PurePosixPath
    tests: tuple[PurePosixPath, ...]


@dataclass(frozen=True)
class Policy:
    roots: tuple[TestRoot, ...] = ()
    owners: tuple[Owner, ...] = ()
    exemptions: tuple[Exemption, ...] = ()
    errors: tuple[str, ...] = ()


@dataclass(frozen=True)
class MarkerError:
    text: str


@dataclass(frozen=True)
class _Table:
    required: frozenset[str]
    optional: frozenset[str] = frozenset()


_TABLES: Final[Mapping[str, _Table]] = {
    "test_root": _Table(frozenset({"source", "tests"})),
    "owner": _Table(frozenset({"source", "tests"})),
    "exempt": _Table(frozenset({"path", "kind"}), frozenset({"reason"})),
}


def is_kind(text: str) -> TypeGuard[Kind]:
    return text in KINDS


def unknown_kind(text: str) -> str:
    return f'unknown kind "{text}"; use one of: {", ".join(KINDS)}'


def read_marker(path: Path) -> Kind | MarkerError | None:
    """The file's header marker kind, an error for an unknown kind, or None."""

    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            head = list(islice(handle, HEADER_LINES))
    except OSError:
        return None
    for line in head:
        found = _MARKER.match(line)
        if found is None:
            continue
        kind = found.group("kind").strip()
        return kind if is_kind(kind) else MarkerError(unknown_kind(kind))
    return None


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
        f"{CONFIG}: unknown table `{key}`"
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
    owners: list[Owner] = []
    for index, entry in enumerate(_entries(document, "owner", errors)):
        source = _text(entry["source"])
        tests = _texts(entry["tests"])
        if source is None or tests is None:
            errors.append(
                f"{CONFIG}: owner[{index}] needs a `source` path and a"
                " non-empty `tests` list of paths"
            )
        elif any(owner.source == PurePosixPath(source) for owner in owners):
            errors.append(f"{CONFIG}: owner {source} is listed twice")
        else:
            owners.append(
                Owner(PurePosixPath(source), tuple(map(PurePosixPath, tests)))
            )
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
    return Policy(tuple(roots), tuple(owners), tuple(exemptions), tuple(errors))


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
