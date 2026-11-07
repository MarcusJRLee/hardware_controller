"""UserPromptSubmit hook: load `mjrlee-*` skills named anywhere in a prompt.

Every mjrlee skill sets `disable-model-invocation: true`, so an agent loads one
only from a leading `/name` (Codex: `$name`) and ignores a mention later in the
message. This hook adds each named skill's `SKILL.md` to that turn's context,
once, so skills stay user-invoked but can be named anywhere. Prompts that name
no skill get no output, so the hook costs nothing in context otherwise.
"""

from __future__ import annotations

import re
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from hook_event import context_output, parse_prompt_event

# Where the machine-wide installer links skills; the first match wins.
SKILL_DIRS: Final = (
    Path.home() / ".claude" / "skills",
    Path.home() / ".agents" / "skills",
)
# A `/mjrlee-x` word, never part of a path such as `skills/mjrlee-x/SKILL.md`.
MENTION: Final = re.compile(
    r"(?<![\w/.~-])/(mjrlee-[a-z0-9]+(?:-[a-z0-9]+)*)(?![\w-])"
)
# Claude Code caps injected context at 10,000 characters and swaps anything
# longer for a file path it never reads; stay under it with headroom.
MAX_CONTEXT: Final = 9000


@dataclass(frozen=True)
class Mentions:
    """Skills a prompt names, in first-mention order."""

    found: tuple[Path, ...]
    unknown: tuple[str, ...]


def _skill_file(name: str, dirs: Sequence[Path]) -> Path | None:
    return next(
        (
            d / name / "SKILL.md"
            for d in dirs
            if (d / name / "SKILL.md").is_file()
        ),
        None,
    )


def mentions(prompt: str, dirs: Sequence[Path]) -> Mentions:
    names: list[str] = []
    for match in MENTION.finditer(prompt):
        # A leading `/name` is the agent's own command: Claude Code has already
        # loaded the skill, and Codex parses it as a slash command.
        if not prompt[: match.start()].strip() or match[1] in names:
            continue
        names.append(str(match[1]))
    found = tuple(f for n in names if (f := _skill_file(n, dirs)))
    unknown = tuple(n for n in names if _skill_file(n, dirs) is None)
    return Mentions(found, unknown)


def render(m: Mentions, dirs: Sequence[Path]) -> str:
    """Return context for the named skills; empty when none was named."""

    if not m.found and not m.unknown:
        return ""
    parts = [
        "The user named these skills in their message; follow each as if "
        "they had run it as a slash command."
    ]
    for skill in m.found:
        name, base = skill.parent.name, skill.parent
        full = f'<skill name="{name}" base_dir="{base}">\n{skill.read_text("utf-8").strip()}\n</skill>'
        pointer = f'<skill name="{name}" base_dir="{base}">\nToo long to include: read {skill} in full before replying.\n</skill>'
        used = sum(len(p) + 1 for p in parts)
        parts.append(full if used + len(full) <= MAX_CONTEXT else pointer)
    if m.unknown:
        installed = sorted(
            {
                d.name
                for root in dirs
                if root.is_dir()
                for d in root.iterdir()
                if d.name.startswith("mjrlee-") and (d / "SKILL.md").is_file()
            }
        )
        named = ", ".join(f"/{n}" for n in m.unknown)
        parts.append(
            f"No installed skill matches {named}; tell the user. "
            f"Installed: {', '.join(installed) or 'none'}."
        )
    return "\n".join(parts)


def main() -> int:
    try:
        event = parse_prompt_event(sys.stdin.read())
    except ValueError as error:
        print(f"expand_skill_mentions: {error}", file=sys.stderr)
        return 1
    context = render(mentions(event.prompt, SKILL_DIRS), SKILL_DIRS)
    if context:
        print(context_output(event, context))
    return 0


if __name__ == "__main__":
    sys.exit(main())
