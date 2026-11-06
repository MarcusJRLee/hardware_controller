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

# Lefthook runs scripts only from `.lefthook/<git hook name>/`, and git's hook
# names are dashed, so that one directory level is allowed.
_LEFTHOOK_DIR: Final = ".lefthook"
_TOOL_MANDATED_NAMES: Final = frozenset(
    {"pnpm-lock.yaml", "pnpm-workspace.yaml", ".python-version"}
)


def dashed_parts(rel: PurePath) -> tuple[str, ...]:
    """Return path components of `rel` that violate the naming rule."""

    if in_skill_tree(rel):
        return ()
    hook_dir = 1 if rel.parts[:1] == (_LEFTHOOK_DIR,) else None
    return tuple(
        part
        for index, part in enumerate(rel.parts)
        if index != hook_dir
        and "-" in part
        and part not in _TOOL_MANDATED_NAMES
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
