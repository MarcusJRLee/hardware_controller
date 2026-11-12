"""Which source files lack a colocated test, for the repo's check gate.

Every source file needs a sibling `<stem>_test.<ext>` in its own directory,
unless an exemption covers it. Test files, `conftest.py`, `*.d.ts`, and the
kit's own installed copies (tested in the kit) are exempt everywhere. Anything
else is exempt only by name: a glob listed with a reason in
`.mjrlee_repo_setup/test_exemptions.toml`, or a header marker. A marker is a
line in the file's first lines that reads, after any comment prefix, the
word `test_exempt:` followed by the reason. A listed glob that matches no
source file is an error, so an exemption cannot outlive what it excused:

    [[exempt]]
    # `*` matches across `/`; a trailing `/` covers a whole directory.
    path = "scripts/*.sh"
    reason = "One-shot operator scripts."

Check the whole repo from its root (exit 1 on any violation):

    uv run --no-project python .mjrlee_repo_setup/hooks/test_ownership.py
"""

from __future__ import annotations

import re
import sys
import tomllib
from collections.abc import Iterable
from dataclasses import dataclass
from fnmatch import fnmatchcase
from itertools import islice
from pathlib import Path, PurePosixPath
from typing import Final

import git_queries

CONFIG: Final = PurePosixPath(".mjrlee_repo_setup/test_exemptions.toml")
SOURCE_SUFFIXES: Final = frozenset(
    {
        ".py",
        ".ts",
        ".tsx",
        ".mts",
        ".cts",
        ".js",
        ".jsx",
        ".mjs",
        ".cjs",
        ".sh",
        ".bash",
        ".go",
        ".rs",
        ".rb",
        ".swift",
        ".kt",
        ".java",
    }
)
# Generated from the kit, whose home repo owns their tests.
BUILT_IN: Final = (
    ".mjrlee_repo_setup/",
    ".lefthook/*/mjrlee_*.sh",
)
HEADER_LINES: Final = 15
_MARKER: Final = re.compile(r"^\s*(?:#|//|/\*|\*|--)?\s*test_exempt:\s*\S")
GUIDANCE: Final = (
    "Test ownership: add a colocated <stem>_test.<ext>, or exempt the file "
    f"with a `test_exempt: <reason>` header line or a glob in {CONFIG}"
)


@dataclass(frozen=True)
class Exemption:
    """A listed glob, or a directory prefix ending in `/`."""

    path: str
    reason: str

    def covers(self, rel: PurePosixPath) -> bool:
        return _matches(self.path, rel)


@dataclass(frozen=True)
class Policy:
    exemptions: tuple[Exemption, ...]
    errors: tuple[str, ...]


def _matches(pattern: str, rel: PurePosixPath) -> bool:
    text = rel.as_posix()
    if pattern.endswith("/"):
        return text.startswith(pattern)
    return fnmatchcase(text, pattern)


def is_test(rel: PurePosixPath) -> bool:
    return rel.stem.endswith("_test") or rel.name == "conftest.py"


def is_source(rel: PurePosixPath) -> bool:
    return (
        rel.suffix in SOURCE_SUFFIXES
        and not is_test(rel)
        and not rel.name.endswith(".d.ts")
        and not any(_matches(pattern, rel) for pattern in BUILT_IN)
    )


def has_test(rel: PurePosixPath, present: frozenset[PurePosixPath]) -> bool:
    stem = f"{rel.stem}_test"
    return any(
        rel.with_name(f"{stem}{suffix}") in present
        for suffix in SOURCE_SUFFIXES
    )


def has_marker(path: Path) -> bool:
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            head = list(islice(handle, HEADER_LINES))
    except OSError:
        return False
    return any(_MARKER.match(line) for line in head)


def _entry_field(entry: object, key: str) -> str | None:
    value = entry.get(key) if isinstance(entry, dict) else None
    return value.strip() if isinstance(value, str) and value.strip() else None


def load_policy(root: Path) -> Policy:
    """Read the repo's exemptions; an absent file means none."""

    path = root / CONFIG
    if not path.is_file():
        return Policy((), ())
    try:
        document = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as error:
        return Policy((), (f"{CONFIG}: {error}",))
    entries: object = document.get("exempt", [])
    if not isinstance(entries, list):
        return Policy((), (f"{CONFIG}: `exempt` must be an array of tables",))
    exemptions: list[Exemption] = []
    errors: list[str] = []
    for index, entry in enumerate(entries):
        listed = _entry_field(entry, "path")
        reason = _entry_field(entry, "reason")
        if listed is None or reason is None:
            errors.append(
                f"{CONFIG}: exempt[{index}] needs a path and a reason"
            )
            continue
        exemptions.append(Exemption(listed, reason))
    return Policy(tuple(exemptions), tuple(errors))


def repo_files(root: Path) -> list[PurePosixPath]:
    """Tracked and untracked-unignored regular files that exist on disk."""

    listed = git_queries.run_git(
        root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"
    )
    names = sorted(set((listed or "").split("\0")) - {""})
    return [
        PurePosixPath(name)
        for name in names
        if (root / name).is_file() and not (root / name).is_symlink()
    ]


def untested(
    root: Path, files: Iterable[PurePosixPath], policy: Policy
) -> list[str]:
    """Return problems: stale exemptions, then untested source files."""

    present = frozenset(files)
    sources = sorted(rel for rel in present if is_source(rel))
    stale = [
        f"{CONFIG}: {e.path} matches no source file; remove it"
        for e in policy.exemptions
        if not any(e.covers(rel) for rel in sources)
    ]
    missing = [
        rel.as_posix()
        for rel in sources
        if not has_test(rel, present)
        and not any(e.covers(rel) for e in policy.exemptions)
        and not has_marker(root / rel)
    ]
    return [*policy.errors, *stale, *missing]


def check(root: Path) -> list[str]:
    return untested(root, repo_files(root), load_policy(root))


def main() -> int:
    root = git_queries.repo_root(Path.cwd())
    if root is None:
        print("error: not inside a git repo", file=sys.stderr)
        return 2
    problems = check(root)
    if problems:
        print(f"{GUIDANCE}:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
