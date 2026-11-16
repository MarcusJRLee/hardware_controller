"""How loaded this machine is: the 1-minute load average per logical CPU.

The load average counts threads that are running or waiting to run (on Linux,
also those blocked on I/O). Past 1.0 per CPU, work queues for a core, so checks
bound by wall-clock time (browser waits, perf budgets, test timeouts) stretch
and flake. It is the one signal every Unix exposes without extra tools or
permissions, and it measures contention from any source: a VM, a game, or
other gates.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from enum import StrEnum
from typing import Final

BUSY_FROM: Final = 0.7
HIGH_FROM: Final = 1.0
# A gate that keeps every core busy reaches about 1.0 per CPU on its own, so a
# sample taken as it ends shows other work only well past that.
HIGH_AFTER_GATE_FROM: Final = 1.5


class Level(StrEnum):
    NORMAL = "normal"
    BUSY = "busy"
    HIGH = "high"


@dataclass(frozen=True)
class LoadSample:
    load: float
    cpus: int

    @property
    def per_cpu(self) -> float:
        return self.load / self.cpus

    def level(self, high_from: float = HIGH_FROM) -> Level:
        if self.per_cpu >= high_from:
            return Level.HIGH
        return Level.BUSY if self.per_cpu >= BUSY_FROM else Level.NORMAL

    def describe(self, high_from: float = HIGH_FROM) -> str:
        return (
            f"load {self.load:.1f} on {self.cpus} CPUs"
            f" ({self.per_cpu:.2f} per CPU, {self.level(high_from)})"
        )


def sample() -> LoadSample | None:
    """Sample now; None where the platform reports no load (e.g. Windows)."""

    try:
        load = os.getloadavg()[0]
    except (AttributeError, OSError):
        return None
    cpus = os.cpu_count()
    return LoadSample(load, cpus) if cpus else None
