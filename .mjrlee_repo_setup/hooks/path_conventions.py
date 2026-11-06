"""Path layouts a spec fixes, shared so the naming and Markdown rules agree."""

from __future__ import annotations

from pathlib import PurePath


def in_skill_tree(rel: PurePath) -> bool:
    """Whether `rel` lies below a `skills/` directory, at any depth.

    The Agent Skills spec fixes each skill's layout: a dashed `<name>/` holding
    `SKILL.md` and `references/`, so neither rule applies inside one.
    """

    return "skills" in rel.parts[:-1]
