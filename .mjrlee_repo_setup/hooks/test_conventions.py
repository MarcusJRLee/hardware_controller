"""Per-language knowledge test_ownership applies with no repo config.

This module owns which files the check reads, which are tests by name, which
names a source's test may have, where toolchains force tests into their own
directory, and which files are exempt by a path every repo shares. Repo
declarations live in test_ownership_policy; the decision lives in
test_ownership.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from dataclasses import dataclass
from fnmatch import fnmatchcase
from pathlib import PurePosixPath
from typing import Final, Literal

Language = Literal["swift", "js", "rust", "python", "other"]
Kind = Literal[
    "thin wrapper",
    "re-export",
    "constants",
    "styles",
    "declarations",
    "generated",
    "test support",
    "one-shot operator script",
    "vendoring tool",
]
# The [Testing] rule's exempt kinds, plus `test support`: code only tests run.
KINDS: Final[tuple[Kind, ...]] = (
    "thin wrapper",
    "re-export",
    "constants",
    "styles",
    "declarations",
    "generated",
    "test support",
    "one-shot operator script",
    "vendoring tool",
)

_LANGUAGES: Final[dict[str, Language]] = {
    ".swift": "swift",
    ".ts": "js",
    ".tsx": "js",
    ".mts": "js",
    ".cts": "js",
    ".js": "js",
    ".jsx": "js",
    ".mjs": "js",
    ".cjs": "js",
    ".rs": "rust",
    ".py": "python",
    ".sh": "other",
    ".bash": "other",
    ".go": "other",
    ".rb": "other",
    ".kt": "other",
    ".java": "other",
}
SOURCE_SUFFIXES: Final = frozenset(_LANGUAGES)
# Test name endings beyond the universal `_test`, per language.
_TEST_ENDINGS: Final[dict[Language, tuple[str, ...]]] = {
    "swift": ("_tests", "Tests"),
    "js": (".test", ".spec"),
}
# Jest's directories of tests and module mocks.
TEST_DIRS: Final = frozenset({"__tests__", "__mocks__"})
# Installed from the kit, whose home repo owns their tests.
_KIT_COPIES: Final = (".mjrlee_repo_setup/", ".lefthook/*/mjrlee_*.sh")
# Tools whose `<tool>[.<variant>].config.<js suffix>` file only configures them.
# A named list, so a repo's own `jobs.config.ts` holding logic is still checked.
_CONFIGURED_TOOLS: Final = (
    "astro",
    "babel",
    "commitlint",
    "drizzle",
    "eslint",
    "jest",
    "metro",
    "next",
    "playwright",
    "postcss",
    "prettier",
    "rollup",
    "svelte",
    "tailwind",
    "tsup",
    "vite",
    "vitest",
    "webpack",
)
_TOOL_CONFIG: Final = re.compile(
    rf"^(?:{'|'.join(_CONFIGURED_TOOLS)})(?:\.[a-z0-9_]+)?\.config\.[cm]?[jt]s$"
)
_BUILT_IN_EXEMPTIONS: Final[tuple[tuple[re.Pattern[str], Kind], ...]] = (
    (re.compile(r"\.d\.[cm]?ts$"), "declarations"),
    (re.compile(r"\.generated\.[^.]+$"), "generated"),
    (re.compile(r"^vendor_"), "vendoring tool"),
    (re.compile(r"_test_(?:fixtures?|support)\.[^.]+$"), "test support"),
    (re.compile(r"^Package\.swift$"), "declarations"),
    (_TOOL_CONFIG, "declarations"),
)
_INLINE_RUST_TESTS: Final = re.compile(r"^\s*#\[cfg\(test\)\]", re.MULTILINE)


@dataclass(frozen=True)
class TestRoot:
    """Sources under `source` are tested by same-stem tests under `tests`.

    Both are directory prefixes ending in `/`, or `""` for the repo root.
    Every file under `tests` is test code.
    """

    source: str
    tests: str


def matches(pattern: str, rel: PurePosixPath) -> bool:
    """A glob where `*` crosses `/`, or a directory prefix ending in `/`."""

    text = rel.as_posix()
    if pattern.endswith("/"):
        return text.startswith(pattern)
    return fnmatchcase(text, pattern)


def language(rel: PurePosixPath) -> Language:
    return _LANGUAGES.get(rel.suffix, "other")


def is_checked(rel: PurePosixPath) -> bool:
    """Whether the check classifies this file at all."""

    return rel.suffix in SOURCE_SUFFIXES and not any(
        matches(pattern, rel) for pattern in _KIT_COPIES
    )


def is_test_name(rel: PurePosixPath) -> bool:
    if rel.name == "conftest.py" or rel.stem.endswith("_test"):
        return True
    if any(part in TEST_DIRS for part in rel.parts[:-1]):
        return True
    return rel.stem.endswith(_TEST_ENDINGS.get(language(rel), ()))


def test_stems(rel: PurePosixPath) -> tuple[str, ...]:
    """Stems a test of `rel` may have, under any checked suffix."""

    endings = ("_test", *_TEST_ENDINGS.get(language(rel), ()))
    return tuple(f"{rel.stem}{ending}" for ending in endings)


def colocated_candidates(rel: PurePosixPath) -> tuple[PurePosixPath, ...]:
    """Paths a colocated test of `rel` may have: beside it, or in `__tests__/`."""

    dirs = [rel.parent]
    if language(rel) == "js":
        dirs.append(rel.parent / "__tests__")
    return tuple(
        directory / f"{stem}{suffix}"
        for directory in dirs
        for stem in test_stems(rel)
        for suffix in sorted(SOURCE_SUFFIXES)
    )


def built_in_exemption(rel: PurePosixPath) -> Kind | None:
    for pattern, kind in _BUILT_IN_EXEMPTIONS:
        if pattern.search(rel.name):
            return kind
    return None


def built_in_roots(files: Iterable[PurePosixPath]) -> tuple[TestRoot, ...]:
    """SwiftPM's `Tests/` and Cargo's `tests/`, wherever a manifest sits."""

    roots: list[TestRoot] = []
    for rel in sorted(files):
        base = "" if rel.parent == PurePosixPath() else f"{rel.parent}/"
        if rel.name == "Package.swift":
            roots.append(TestRoot(f"{base}Sources/", f"{base}Tests/"))
        elif rel.name == "Cargo.toml":
            roots.append(TestRoot(f"{base}src/", f"{base}tests/"))
    return tuple(roots)


def has_inline_tests(rel: PurePosixPath, text: str) -> bool:
    """Rust's colocation: a `#[cfg(test)]` module in the source itself."""

    return language(rel) == "rust" and bool(_INLINE_RUST_TESTS.search(text))
