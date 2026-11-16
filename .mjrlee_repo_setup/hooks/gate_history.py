"""A repo's bounded pre-push timing history, one JSON object per line.

It lives in git's common dir (`.git/` of the main checkout), which every
worktree shares: git never tracks it, so it needs no .gitignore entry; no
formatter or watcher on a working tree sees it; and the trend outlives each
worktree, which is removed once its PR merges.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from collections.abc import Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Final

import machine_load

FILE_NAME: Final = "mjrlee_gate_history.jsonl"
# Enough runs for a trend at a few KB; older runs say little about today's gate.
LIMIT: Final = 50


@dataclass(frozen=True)
class Run:
    at: str  # ISO 8601, UTC.
    seconds: float
    budget_seconds: int
    exit_code: int
    # Load per CPU as the gate started and ended; None where unmeasured.
    load_before: float | None
    load_after: float | None

    @property
    def over_budget(self) -> bool:
        return self.seconds > self.budget_seconds

    @property
    def under_load(self) -> bool:
        """Whether other work likely slowed it (see `machine_load`)."""

        return (self.load_before or 0) >= machine_load.HIGH_FROM or (
            self.load_after or 0
        ) >= machine_load.HIGH_AFTER_GATE_FROM


def _number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    return float(value)


def _run(line: str) -> Run | None:
    try:
        raw: object = json.loads(line)
    except ValueError:
        return None
    if not isinstance(raw, dict):
        return None
    at, seconds = raw.get("at"), _number(raw.get("seconds"))
    budget, code = raw.get("budget_seconds"), raw.get("exit_code")
    if (
        not isinstance(at, str)
        or seconds is None
        or not isinstance(budget, int)
        or not isinstance(code, int)
    ):
        return None
    return Run(
        at,
        seconds,
        budget,
        code,
        _number(raw.get("load_before")),
        _number(raw.get("load_after")),
    )


def path(root: Path) -> Path | None:
    """The history file for `root`'s repo; None outside a git checkout."""

    result = subprocess.run(
        [  # noqa: S607 - git is on PATH.
            "git",
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    common = result.stdout.strip()
    return (
        Path(common) / FILE_NAME if result.returncode == 0 and common else None
    )


def read(file: Path) -> list[Run]:
    """Runs oldest first; lines that are not runs are skipped."""

    try:
        text = file.read_text(encoding="utf-8")
    except FileNotFoundError:
        return []
    return [run for line in text.splitlines() if (run := _run(line))]


def append(file: Path, run: Run, limit: int = LIMIT) -> list[Run]:
    """Add `run`, keep the newest `limit` runs, and return them.

    The replace is atomic, so a reader never sees a partial file. Two gates
    ending at once can each drop the other's run; a lock would cost more than
    one lost sample of soft telemetry.
    """

    runs = [*read(file), run][-limit:]
    text = "".join(json.dumps(asdict(r)) + "\n" for r in runs)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=file.parent,
        prefix=f".{file.name}.",
        delete=False,
    ) as tmp:
        try:
            tmp.write(text)
            tmp.close()
            os.replace(tmp.name, file)
        except OSError:
            Path(tmp.name).unlink(missing_ok=True)
            raise
    return runs


def passing_at_normal_load(runs: Sequence[Run]) -> list[Run]:
    """Runs that measure the full gate itself: passed, and not slowed by load."""

    return [r for r in runs if r.exit_code == 0 and not r.under_load]
