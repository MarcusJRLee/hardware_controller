"""Normalize Claude Code and Codex hook payloads into one typed event.

Both agents send a JSON object on stdin. Claude Code reports file edits as
`Edit`/`MultiEdit`/`Write` with `tool_input.file_path`; Codex reports them as
`apply_patch` with the patch text in `tool_input.command`.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Final

_CLAUDE_FILE_TOOLS: Final = frozenset({"Edit", "MultiEdit", "Write"})
_PATCH_PATH_PREFIXES: Final = (
    "*** Add File: ",
    "*** Update File: ",
    "*** Move to: ",
)


@dataclass(frozen=True)
class HookEvent:
    """The subset of a hook payload that repo hooks act on."""

    event_name: str
    cwd: Path
    tool_name: str
    # Shell command text; None for non-shell tools.
    command: str | None
    # Absolute paths a file-edit tool created or modified; deletions excluded.
    written_paths: tuple[Path, ...]


def _field(obj: object, key: str) -> object:
    return obj.get(key) if isinstance(obj, dict) else None


def _str_field(obj: object, key: str) -> str | None:
    value = _field(obj, key)
    return value if isinstance(value, str) else None


def patch_written_paths(patch: str) -> tuple[str, ...]:
    """Return paths an apply_patch body adds, updates, or moves to."""

    return tuple(
        line.removeprefix(prefix).strip()
        for line in patch.splitlines()
        for prefix in _PATCH_PATH_PREFIXES
        if line.startswith(prefix)
    )


def parse_event(raw: str) -> HookEvent:
    """Parse a hook payload; raises ValueError when required fields are absent."""

    payload: object = json.loads(raw)
    event_name = _str_field(payload, "hook_event_name")
    cwd = _str_field(payload, "cwd")
    tool_name = _str_field(payload, "tool_name")
    if event_name is None or cwd is None or tool_name is None:
        msg = "hook payload lacks hook_event_name, cwd, or tool_name"
        raise ValueError(msg)

    tool_input = _field(payload, "tool_input")
    command: str | None = None
    raw_paths: tuple[str, ...] = ()
    if tool_name == "Bash":
        command = _str_field(tool_input, "command")
    elif tool_name == "apply_patch":
        raw_paths = patch_written_paths(_str_field(tool_input, "command") or "")
    elif tool_name in _CLAUDE_FILE_TOOLS:
        file_path = _str_field(tool_input, "file_path")
        raw_paths = (file_path,) if file_path else ()

    base = Path(cwd)
    return HookEvent(
        event_name=event_name,
        cwd=base,
        tool_name=tool_name,
        command=command,
        written_paths=tuple((base / p).resolve() for p in raw_paths),
    )


def deny_output(event: HookEvent, reason: str) -> str:
    """Render a PreToolUse decision that blocks the call in both agents.

    Blocking is only ever this explicit decision; the rendered hook command
    turns every non-zero exit into a non-blocking error.
    """

    return json.dumps(
        {
            "hookSpecificOutput": {
                "hookEventName": event.event_name,
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }
    )


def context_output(event: HookEvent | PromptEvent, message: str) -> str:
    """Render non-blocking feedback that both agents add to the model context."""

    return json.dumps(
        {
            "hookSpecificOutput": {
                "hookEventName": event.event_name,
                "additionalContext": message,
            }
        }
    )


@dataclass(frozen=True)
class WorktreeEvent:
    """A Claude Code WorktreeCreate or WorktreeRemove payload."""

    event_name: str
    cwd: Path
    # WorktreeCreate: the requested worktree name; None for WorktreeRemove.
    name: str | None
    # WorktreeRemove: the worktree to remove; None for WorktreeCreate.
    worktree_path: Path | None


def parse_worktree_event(raw: str) -> WorktreeEvent:
    """Parse a worktree lifecycle payload; raises ValueError when malformed."""

    payload: object = json.loads(raw)
    event_name = _str_field(payload, "hook_event_name")
    cwd = _str_field(payload, "cwd")
    name = _str_field(payload, "name")
    path = _str_field(payload, "worktree_path")
    if event_name == "WorktreeCreate" and cwd and name is not None:
        return WorktreeEvent(event_name, Path(cwd), name, None)
    if event_name == "WorktreeRemove" and cwd and path:
        return WorktreeEvent(event_name, Path(cwd), None, Path(path))
    msg = "payload is not a WorktreeCreate with name or WorktreeRemove with worktree_path"
    raise ValueError(msg)


@dataclass(frozen=True)
class PromptEvent:
    """A UserPromptSubmit payload; both agents send the raw prompt text."""

    event_name: str
    cwd: Path
    prompt: str


def parse_prompt_event(raw: str) -> PromptEvent:
    """Parse a UserPromptSubmit payload; raises ValueError when malformed."""

    payload: object = json.loads(raw)
    event_name = _str_field(payload, "hook_event_name")
    cwd = _str_field(payload, "cwd")
    prompt = _str_field(payload, "prompt")
    if event_name != "UserPromptSubmit" or not cwd or prompt is None:
        msg = "payload is not a UserPromptSubmit with cwd and prompt"
        raise ValueError(msg)
    return PromptEvent(event_name, Path(cwd), prompt)
