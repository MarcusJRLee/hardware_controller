"""Which source files lack a test, for the repo's check gate.

Every checked file is a test or a source. A source is tested by, in order:

- colocated: `<stem>_test.<ext>` beside it; JS/TS also take `.test`/`.spec`
  names and a sibling `__tests__/`.
- test_root: a same-stem test under SwiftPM's `Tests/`, Cargo's `tests/`, or a
  `[[test_root]]` (Swift also takes `_tests` and `Tests` stems).
- inline: a Rust `#[cfg(test)]` module in the source itself.
- owner: an `[[owner]]` entry naming the tests that cover it.

Otherwise it needs an exemption naming a kind: a header marker, an `[[exempt]]`
glob, or a built-in path rule (declarations, generated, vendoring tools, tool
configs, test fixtures). test_conventions holds the language knowledge;
test_ownership_policy holds the config format. Stale, redundant, and unknown
entries fail, so no declaration outlives what it excused.

Check the whole repo from its root (exit 1 on any problem); `--json` prints each
file's decision for tools such as coverage gates:

    uv run --no-project python .mjrlee_repo_setup/hooks/test_ownership.py
    uv run --no-project python .mjrlee_repo_setup/hooks/test_ownership.py --json
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Final, Literal, TypedDict

import git_queries
from test_conventions import (
    Kind,
    TestRoot,
    built_in_exemption,
    built_in_roots,
    colocated_candidates,
    has_inline_tests,
    is_checked,
    is_test_name,
    matches,
    test_stems,
)
from test_ownership_policy import (
    CONFIG,
    Exemption,
    MarkerError,
    Policy,
    load_policy,
    read_marker,
)

REPORT_VERSION: Final = 1
GUIDANCE: Final = (
    "Test ownership: add a test named for the source, or declare an owner, a"
    f" test root, or an exemption in {CONFIG} or a `Test exemption: <kind>.`"
    " header line"
)

Role = Literal["test", "source"]
Status = Literal["tested", "exempt", "untested"]
Via = Literal[
    "colocated", "test_root", "inline", "owner", "marker", "path", "built_in"
]


@dataclass(frozen=True)
class Decision:
    path: PurePosixPath
    role: Role
    status: Status | None = None
    via: Via | None = None
    kind: Kind | None = None
    tests: tuple[PurePosixPath, ...] = ()


@dataclass(frozen=True)
class Report:
    decisions: tuple[Decision, ...]
    problems: tuple[str, ...]


class DecisionJson(TypedDict):
    path: str
    role: Role
    status: Status | None
    via: Via | None
    kind: Kind | None
    tests: list[str]


class ReportJson(TypedDict):
    version: int
    files: list[DecisionJson]
    problems: list[str]


class _Context:
    """Indexes one repo's files so each source's decision is a lookup."""

    def __init__(
        self, root: Path, files: Iterable[PurePosixPath], policy: Policy
    ):
        self.root = root
        self.policy = policy
        self.present = frozenset(files)
        self.checked = sorted(rel for rel in self.present if is_checked(rel))
        built_in = built_in_roots(self.present)
        self.redundant_roots = [r for r in policy.roots if r in built_in]
        self.roots = (
            *built_in,
            *(r for r in policy.roots if r not in built_in),
        )
        self.tests = frozenset(
            rel for rel in self.checked if self._is_test(rel)
        )
        self.stems: dict[TestRoot, dict[str, list[PurePosixPath]]] = {}
        for test_root in self.roots:
            stems: dict[str, list[PurePosixPath]] = defaultdict(list)
            for rel in self.tests:
                if matches(test_root.tests, rel):
                    stems[rel.stem].append(rel)
            self.stems[test_root] = stems
        self.owners = {owner.source: owner for owner in policy.owners}

    def _is_test(self, rel: PurePosixPath) -> bool:
        return is_test_name(rel) or any(
            matches(test_root.tests, rel) for test_root in self.roots
        )

    def natural_tests(
        self, rel: PurePosixPath
    ) -> tuple[Via, tuple[PurePosixPath, ...]] | None:
        colocated = tuple(
            p for p in colocated_candidates(rel) if p in self.tests
        )
        if colocated:
            return "colocated", colocated
        rooted = tuple(
            test
            for test_root in self.roots
            if matches(test_root.source, rel)
            for stem in test_stems(rel)
            for test in self.stems[test_root].get(stem, ())
        )
        if rooted:
            return "test_root", tuple(sorted(set(rooted)))
        if rel.suffix == ".rs":
            text = (self.root / rel).read_text(
                encoding="utf-8", errors="replace"
            )
            if has_inline_tests(rel, text):
                return "inline", ()
        return None


def _source_decision(
    context: _Context,
    rel: PurePosixPath,
    used: set[Exemption],
    problems: list[str],
) -> Decision:
    marker = read_marker(context.root / rel)
    if isinstance(marker, MarkerError):
        problems.append(f"{rel}: test exemption marker has {marker.text}")
        marker = None
    exemption = next(
        (e for e in context.policy.exemptions if e.covers(rel)), None
    )
    built_in = built_in_exemption(rel)
    owner = context.owners.get(rel)
    natural = context.natural_tests(rel)
    if marker is not None and (natural is not None or owner is not None):
        problems.append(
            f"{rel}: has a test, so its test exemption marker is redundant"
        )
    if natural is not None:
        if owner is not None:
            problems.append(
                f"{CONFIG}: owner {rel} has its own test; remove it"
            )
        return Decision(rel, "source", "tested", natural[0], tests=natural[1])
    if owner is not None:
        return Decision(rel, "source", "tested", "owner", tests=owner.tests)
    if marker is not None:
        if exemption is not None or built_in is not None:
            problems.append(
                f"{rel}: exempt by path, so its test exemption marker is redundant"
            )
        return Decision(rel, "source", "exempt", "marker", marker)
    if exemption is not None:
        used.add(exemption)
        return Decision(rel, "source", "exempt", "path", exemption.kind)
    if built_in is not None:
        return Decision(rel, "source", "exempt", "built_in", built_in)
    return Decision(rel, "source", "untested")


def _stale_declarations(context: _Context, used: set[Exemption]) -> list[str]:
    sources = [rel for rel in context.checked if rel not in context.tests]
    problems = [
        f"{CONFIG}: test_root {r.source} -> {r.tests} is built in; remove it"
        for r in context.redundant_roots
    ]
    for test_root in context.policy.roots:
        if not any(matches(test_root.source, rel) for rel in sources):
            problems.append(
                f"{CONFIG}: test_root {test_root.source} holds no source; remove it"
            )
        if not any(matches(test_root.tests, rel) for rel in context.tests):
            problems.append(
                f"{CONFIG}: test_root {test_root.tests} holds no test; remove it"
            )
    for owner in context.policy.owners:
        if owner.source not in context.checked or owner.source in context.tests:
            problems.append(
                f"{CONFIG}: owner {owner.source} is not a source file; remove it"
            )
        problems.extend(
            f"{CONFIG}: owner {owner.source} names {test}, which is not a test file"
            for test in owner.tests
            if test not in context.tests
        )
    problems.extend(
        f"{CONFIG}: exempt {e.path} excuses no untested source; remove it"
        for e in context.policy.exemptions
        if e not in used
    )
    return problems


def decide(
    root: Path, files: Iterable[PurePosixPath], policy: Policy
) -> Report:
    context = _Context(root, files, policy)
    used: set[Exemption] = set()
    problems: list[str] = []
    decisions = [
        Decision(rel, "test")
        if rel in context.tests
        else _source_decision(context, rel, used, problems)
        for rel in context.checked
    ]
    untested = [d.path.as_posix() for d in decisions if d.status == "untested"]
    return Report(
        tuple(decisions),
        (
            *policy.errors,
            *_stale_declarations(context, used),
            *problems,
            *untested,
        ),
    )


def to_json(report: Report) -> ReportJson:
    return {
        "version": REPORT_VERSION,
        "files": [
            {
                "path": d.path.as_posix(),
                "role": d.role,
                "status": d.status,
                "via": d.via,
                "kind": d.kind,
                "tests": [test.as_posix() for test in d.tests],
            }
            for d in report.decisions
        ],
        "problems": list(report.problems),
    }


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


def check(root: Path) -> Report:
    return decide(root, repo_files(root), load_policy(root))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Report sources that lack a test."
    )
    parser.add_argument(
        "--json", action="store_true", help="Print every decision as JSON."
    )
    args = parser.parse_args(argv)
    root = git_queries.repo_root(Path.cwd())
    if root is None:
        print("error: not inside a git repo", file=sys.stderr)
        return 2
    report = check(root)
    if args.json:
        print(json.dumps(to_json(report), indent=2))
    elif report.problems:
        print(f"{GUIDANCE}:", file=sys.stderr)
        for problem in report.problems:
            print(f"  {problem}", file=sys.stderr)
    return 1 if report.problems else 0


if __name__ == "__main__":
    sys.exit(main())
