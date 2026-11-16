"""Load-aware, time-budgeted report around a kit repo's whole pre-push hook.

`lefthook_rc.sh` runs `start` before lefthook and `finish` after it, so every
pre-push script (the repo's gate and the kit's rules) is covered with no
per-repo wiring. It only informs: it never changes the hook's exit code.

    uv run --no-project python .mjrlee_repo_setup/hooks/gate_report.py history

| Line                     | When                                                         |
| ------------------------ | ------------------------------------------------------------ |
| Load against CPU count   | Every push, as it starts; with advice at 1.0+ per CPU.       |
| Failure likely from load | It failed with 1.0+ per CPU at start, or 1.5+ at the end.    |
| Over budget              | It ran past `[pre_push] budget_seconds` in `repo.toml`.      |
| Roadmap suggestion       | Also, 3 of the last 5 passing runs at normal load were over. |

`history` prints the recent runs (`gate_history.py` says where they live).
"""

from __future__ import annotations

import argparse
import sys
import time
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Final

import gate_history
import machine_load
import repo_config
from gate_history import Run
from machine_load import Level, LoadSample

PREFIX: Final = "pre-push gate:"
LOAD_ADVICE: Final = "retry once load drops, or run fewer gates in parallel"
# A trend is TREND_OVER of the last TREND_RUNS passing runs at normal load.
TREND_RUNS: Final = 5
TREND_OVER: Final = 3
ROADMAP_NEW: Final = (
    "uv run --no-project python .mjrlee_repo_setup/tools/roadmap.py new"
    ' speed_up_pre_push --title "Speed up the pre-push gate"'
)


def duration(seconds: float) -> str:
    whole = round(seconds)
    return f"{whole}s" if whole < 60 else f"{whole // 60}m{whole % 60:02d}s"


def start_line(load: LoadSample) -> str:
    line = f"{PREFIX} {load.describe()}."
    if load.level() is Level.HIGH:
        line += f" Checks with timeouts may fail; if one does, {LOAD_ADVICE}."
    return line


def state(started: float, load: LoadSample | None) -> str:
    """The token `start` hands `finish` through the hook's shell."""

    return f"{started}:{load.load}:{load.cpus}" if load else f"{started}"


def parse_state(token: str) -> tuple[float, LoadSample | None] | None:
    parts = token.split(":")
    try:
        started = float(parts[0])
        if len(parts) == 3 and (cpus := int(parts[2])) > 0:
            return started, LoadSample(float(parts[1]), cpus)
    except ValueError:
        return None
    return (started, None) if len(parts) == 1 else None


def finish_lines(
    run: Run,
    before: LoadSample | None,
    after: LoadSample | None,
    runs: Sequence[Run],
) -> list[str]:
    """What to tell the pusher about `run`, the newest of `runs`."""

    lines: list[str] = []
    loaded = next(
        (
            (when, load, bar)
            for when, load, bar in (
                ("as it started", before, machine_load.HIGH_FROM),
                ("as it ended", after, machine_load.HIGH_AFTER_GATE_FROM),
            )
            if load and load.level(bar) is Level.HIGH
        ),
        None,
    )
    if run.exit_code != 0 and loaded:
        when, load, bar = loaded
        lines.append(
            f"{PREFIX} failed with the machine loaded {when}"
            f" ({load.describe(bar)}); a timeout or flake is likely"
            f" load-related: {LOAD_ADVICE}."
        )
    if run.over_budget:
        line = (
            f"{PREFIX} took {duration(run.seconds)}, over this repo's"
            f" {duration(run.budget_seconds)} budget (`[pre_push]"
            f" budget_seconds = {run.budget_seconds}` in {repo_config.CONFIG})."
        )
        if run.under_load:
            line += " High load likely stretched it."
        lines.append(line)
        recent = gate_history.passing_at_normal_load(runs)[-TREND_RUNS:]
        over = sum(r.over_budget for r in recent)
        if over >= TREND_OVER:
            lines.append(
                f"{PREFIX} {over} of the last {len(recent)} passing runs at"
                " normal load went over budget; add a roadmap item to speed"
                " up the gate, or raise the budget if its length is"
                f" intended: {ROADMAP_NEW}"
            )
    return lines


def budget(root: Path) -> int:
    # A malformed repo.toml fails the push through launch_rule.py already.
    try:
        return repo_config.load(root).pre_push_budget
    except repo_config.RepoConfigError:
        return repo_config.DEFAULT_PRE_PUSH_BUDGET


def finish(root: Path, exit_code: int, token: str, now: float) -> list[str]:
    parsed = parse_state(token)
    if parsed is None or now < parsed[0]:
        return []  # No start, or the clock moved back: nothing to time.
    started, before = parsed
    after = machine_load.sample()
    run = Run(
        at=datetime.fromtimestamp(started, UTC).isoformat(timespec="seconds"),
        seconds=round(now - started, 1),
        budget_seconds=budget(root),
        exit_code=exit_code,
        load_before=before.per_cpu if before else None,
        load_after=after.per_cpu if after else None,
    )
    file = gate_history.path(root)
    if file is None:
        return finish_lines(run, before, after, [run])
    try:
        runs = gate_history.append(file, run)
    except OSError:
        runs = [run]  # A read-only git dir loses the trend, never the push.
    return finish_lines(run, before, after, runs)


def history_lines(root: Path) -> list[str]:
    file = gate_history.path(root)
    runs = gate_history.read(file) if file else []
    if not file or not runs:
        return ["No pre-push runs recorded yet."]

    def load(value: float | None) -> str:
        return "-" if value is None else f"{value:.2f}"

    return [
        f"Pre-push runs, newest last ({file}):",
        *(
            f"{r.at}  {duration(r.seconds):>7} of {duration(r.budget_seconds)}"
            f"  {'over' if r.over_budget else 'ok  '}  exit {r.exit_code}"
            f"  load/CPU {load(r.load_before)}->{load(r.load_after)}"
            for r in runs
        ),
    ]


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("start", help="Print load; print the state token.")
    end = sub.add_parser("finish", help="Record the run; warn if needed.")
    end.add_argument("exit_code", type=int)
    end.add_argument("state", nargs="?", default="")
    sub.add_parser("history", help="Print the recorded runs.")
    args = parser.parse_args(argv)
    root = Path.cwd()
    if args.command == "start":
        load = machine_load.sample()
        if load:
            print(start_line(load), file=sys.stderr)
        print(state(time.time(), load))
    elif args.command == "finish":
        for line in finish(root, args.exit_code, args.state, time.time()):
            print(line, file=sys.stderr)
    else:
        print("\n".join(history_lines(root)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
