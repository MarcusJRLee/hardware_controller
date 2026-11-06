"""PostToolUse hook: warn when the agent authors a dashed file or dir name.

Enforces the naming rule in the kit's AGENTS.md rules: lowercase_with_underscores,
except inside skill trees and for names a tool mandates. Only names new to git
are checked, so existing paths never trigger warnings.
"""

from __future__ import annotations

import sys
from pathlib import Path, PurePath
from typing import Final

import git_queries
from hook_event import context_output, parse_event
from path_conventions import in_skill_tree

# Git's client hook names (githooks(5)); lefthook runs scripts only from a
# `.lefthook/<hook>/` directory named after one.
_GIT_HOOK_NAMES: Final = frozenset(
    {
        "applypatch-msg",
        "commit-msg",
        "post-applypatch",
        "post-checkout",
        "post-commit",
        "post-merge",
        "post-rewrite",
        "pre-applypatch",
        "pre-auto-gc",
        "pre-commit",
        "pre-merge-commit",
        "pre-push",
        "pre-rebase",
        "prepare-commit-msg",
    }
)
_TOOL_MANDATED_NAMES: Final = _GIT_HOOK_NAMES | frozenset(
    {"pnpm-lock.yaml", "pnpm-workspace.yaml", ".python-version"}
)


def dashed_parts(rel: PurePath) -> tuple[str, ...]:
    """Return path components of `rel` that violate the naming rule."""

    if in_skill_tree(rel):
        return ()
    return tuple(
        part
        for part in rel.parts
        if "-" in part and part not in _TOOL_MANDATED_NAMES
    )


def new_dashed_parts(root: Path, path: Path) -> tuple[str, ...]:
    """Return violating components of `path` that git does not know yet."""

    rel = path.relative_to(root)
    violations: list[str] = []
    for depth, part in enumerate(rel.parts, start=1):
        if part not in dashed_parts(rel):
            continue
        if not git_queries.is_known_path(
            root, root.joinpath(*rel.parts[:depth])
        ):
            violations.append(part)
    return tuple(violations)


def main() -> int:
    event = parse_event(sys.stdin.read())
    root = git_queries.repo_root(event.cwd)
    if root is None:
        return 0
    warnings = [
        f"`{path.relative_to(root)}` ({', '.join(parts)})"
        for path in event.written_paths
        if path.is_relative_to(root) and (parts := new_dashed_parts(root, path))
    ]
    if warnings:
        print(
            context_output(
                event,
                "Naming rule: use lowercase_with_underscores, not dashes. "
                "Rename unless a tool mandates the name: "
                + "; ".join(warnings),
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
