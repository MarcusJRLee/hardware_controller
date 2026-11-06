"""Where Markdown may live, for the placement hook and the repo-wide check.

One place per kind of document prevents drift, so Markdown is allowed only as a
directory's `README.md`, as root `AGENTS.md` or `CLAUDE.md`, or under root
`docs/`. Two places a tool fixes are allowed too: skill trees, and `.github/`,
where GitHub reads PR and issue templates. Any other path must be listed in
`.mjrlee_repo_setup/markdown_paths.toml` with a reason; a listed path that no
longer exists is an error, so an exception cannot outlive what it excused.

Check the whole repo from its root (exit 1 on any violation):

    uv run --no-project python .mjrlee_repo_setup/hooks/markdown_placement.py
"""

from __future__ import annotations

import sys
import tomllib
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Final

import git_queries
from path_conventions import in_skill_tree

CONFIG: Final = PurePosixPath(".mjrlee_repo_setup/markdown_paths.toml")
_ROOT_FILES: Final = frozenset({"AGENTS.md", "CLAUDE.md"})
GUIDANCE: Final = (
    "Markdown placement: move it under docs/ or into its directory's "
    f"README.md, or list it with a reason in {CONFIG}"
)


@dataclass(frozen=True)
class Allowance:
    """A listed exception: an exact file, or a directory ending in `/`."""

    path: str
    reason: str

    def covers(self, rel: PurePosixPath) -> bool:
        text = rel.as_posix()
        return text == self.path or (
            self.path.endswith("/") and text.startswith(self.path)
        )


@dataclass(frozen=True)
class Policy:
    allowances: tuple[Allowance, ...]
    errors: tuple[str, ...]

    def allows(self, rel: PurePosixPath) -> bool:
        if rel.suffix != ".md" or rel.name == "README.md":
            return True
        if len(rel.parts) == 1 and rel.name in _ROOT_FILES:
            return True
        if len(rel.parts) > 1 and rel.parts[0] in {"docs", ".github"}:
            return True
        if in_skill_tree(rel):
            return True
        return any(a.covers(rel) for a in self.allowances)


def _entry_field(entry: object, key: str) -> str | None:
    value = entry.get(key) if isinstance(entry, dict) else None
    return value.strip() if isinstance(value, str) and value.strip() else None


def load_policy(root: Path) -> Policy:
    """Read the repo's exceptions; an absent file means none."""

    path = root / CONFIG
    if not path.is_file():
        return Policy((), ())
    try:
        document = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as error:
        return Policy((), (f"{CONFIG}: {error}",))
    entries: object = document.get("allow", [])
    if not isinstance(entries, list):
        return Policy((), (f"{CONFIG}: `allow` must be an array of tables",))
    allowances: list[Allowance] = []
    errors: list[str] = []
    for index, entry in enumerate(entries):
        listed = _entry_field(entry, "path")
        reason = _entry_field(entry, "reason")
        if listed is None or reason is None:
            errors.append(f"{CONFIG}: allow[{index}] needs a path and a reason")
            continue
        if not (root / listed).exists():
            errors.append(f"{CONFIG}: {listed} no longer exists; remove it")
        allowances.append(Allowance(listed, reason))
    return Policy(tuple(allowances), tuple(errors))


def misplaced(root: Path, paths: Iterable[Path], policy: Policy) -> list[str]:
    """Return repo-relative paths among `paths` that the policy rejects."""

    return [
        rel.as_posix()
        for path in paths
        if path.is_relative_to(root)
        and not policy.allows(rel := PurePosixPath(path.relative_to(root)))
    ]


def repo_markdown(root: Path) -> list[Path]:
    """Tracked and untracked-unignored Markdown files that exist on disk."""

    listed = git_queries.run_git(
        root,
        "ls-files",
        "-z",
        "--cached",
        "--others",
        "--exclude-standard",
        "--",
        "*.md",
    )
    names = sorted(set((listed or "").split("\0")) - {""})
    return [root / name for name in names if (root / name).is_file()]


def check(root: Path) -> list[str]:
    policy = load_policy(root)
    return [
        *policy.errors,
        *misplaced(root, repo_markdown(root), policy),
    ]


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
