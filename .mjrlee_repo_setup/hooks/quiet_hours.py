"""Quiet hours: weekly windows in which a repo records no work.

`repo.toml`'s `[quiet_hours]` table (format in `repo_config.py`) declares them.
Inside a window nothing that an audit would read as work happens: no commit is
created or pushed, and agents make no GitHub writes. `quiet_hours_rule.py`
enforces this in git hooks and `guard_git.py` for agent commands.

Invariants:

- Window times are wall-clock times in the table's `timezone`, compared as
  absolute instants, so DST shifts and a commit's own UTC offset never move a
  window.
- The kit only blocks. It never rewrites, backdates, or forward-dates a commit
  to fall outside a window.
- Comments, prompts, and messages say what quiet hours block, never why a repo
  has them.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from typing import Final
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DAYS: Final = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
_WINDOW_KEYS: Final = frozenset({"days", "start", "end"})
_CLOCK: Final = re.compile(r"([01]\d|2[0-3]):([0-5]\d)")
# The midnight that ends a window's start day; valid only as `end`.
END_OF_DAY: Final = "24:00"
# A quiet period can chain through at most every window of one week, plus the
# day either side, before validation guarantees an open instant.
_HORIZON_DAYS: Final = 9


class QuietHoursError(ValueError):
    """`[quiet_hours]` is malformed; the message names the field."""


@dataclass(frozen=True)
class Window:
    """A daily stretch, starting on each of `days`, that may cross midnight."""

    # `date.weekday()` numbers of the days the window starts on.
    days: frozenset[int]
    start: time
    # None: the midnight ending the start day.
    end: time | None

    def span(self, day: date, zone: ZoneInfo) -> tuple[datetime, datetime]:
        """Return the window's start and end instants when it starts on `day`."""

        crosses = self.end is None or self.end <= self.start
        end_day = day + timedelta(days=1) if crosses else day
        start = datetime.combine(day, self.start, zone)
        return start, datetime.combine(end_day, self.end or time(0), zone)


@dataclass(frozen=True)
class QuietHours:
    zone: ZoneInfo
    windows: tuple[Window, ...]

    def _spans(self, around: datetime) -> Iterator[tuple[float, float]]:
        # Timestamps, never aware datetimes: those sharing one tzinfo compare
        # by wall clock, which misorders the repeated hour of a DST fall-back.
        local = around.astimezone(self.zone).date()
        for offset in range(-1, _HORIZON_DAYS):
            day = local + timedelta(days=offset)
            for window in self.windows:
                if day.weekday() in window.days:
                    start, end = window.span(day, self.zone)
                    yield start.timestamp(), end.timestamp()

    def _containing(self, instant: datetime) -> float | None:
        moment = instant.timestamp()
        ends = [e for s, e in self._spans(instant) if s <= moment < e]
        return max(ends) if ends else None

    def quiet_until(self, instant: datetime) -> datetime | None:
        """Return when the quiet period holding `instant` ends, else None.

        Overlapping and back-to-back windows form one period.
        """

        end = self._containing(instant)
        if end is None:
            return None
        for _ in range(len(self.windows) * _HORIZON_DAYS):
            cursor = datetime.fromtimestamp(end, self.zone)
            later = self._containing(cursor)
            if later is None:
                return cursor
            end = later
        # Unreachable for a validated table, which leaves open time each week.
        msg = "quiet hours never end"
        raise QuietHoursError(msg)

    def next_start(self, instant: datetime) -> datetime | None:
        """Return the next window start after `instant`, or None if none."""

        moment = instant.timestamp()
        starts = [s for s, _ in self._spans(instant) if s > moment]
        return (
            datetime.fromtimestamp(min(starts), self.zone) if starts else None
        )

    def leaves_open_time(self) -> bool:
        """Whether some instant of every week falls outside all windows."""

        # Every quiet period ends at some window's end, so the week has open
        # time exactly when one window end in a sample week is outside all.
        week = datetime(2001, 1, 1, tzinfo=self.zone)  # A Monday.
        return not self.windows or any(
            self._containing(datetime.fromtimestamp(e, self.zone)) is None
            for _, e in self._spans(week)
        )

    def describe(self, instant: datetime) -> str:
        """Render `instant` as the table's wall clock, e.g. `Fri 17:00 UTC`."""

        return f"{instant.astimezone(self.zone):%a %H:%M} {self.zone.key}"


def _clock(value: object, where: str) -> time:
    match = _CLOCK.fullmatch(value) if isinstance(value, str) else None
    if match is None:
        raise QuietHoursError(f'{where} must be a "HH:MM" string')
    return time(int(match[1]), int(match[2]))


def _end(value: object, where: str) -> time | None:
    if value == END_OF_DAY:
        return None
    try:
        return _clock(value, where)
    except QuietHoursError as error:
        msg = f'{error} or "{END_OF_DAY}"'
        raise QuietHoursError(msg) from None


def _days(value: object, where: str) -> frozenset[int]:
    items = value if isinstance(value, list) else None
    if not items or not all(d in DAYS for d in items):
        msg = f"{where} must be a non-empty list of {', '.join(DAYS)}"
        raise QuietHoursError(msg)
    if len(set(items)) != len(items):
        raise QuietHoursError(f"{where} lists a day twice")
    return frozenset(DAYS.index(d) for d in items)


def _window(value: object, where: str) -> Window:
    if not isinstance(value, dict):
        raise QuietHoursError(f"{where} must be a table")
    if set(value) != _WINDOW_KEYS:
        msg = f"{where} must have exactly the keys days, start, end"
        raise QuietHoursError(msg)
    start = _clock(value.get("start"), f"{where}.start")
    end = _end(value.get("end"), f"{where}.end")
    if start == end:
        raise QuietHoursError(f"{where}.start and end must differ")
    return Window(_days(value.get("days"), f"{where}.days"), start, end)


def _zone(value: object, where: str) -> ZoneInfo:
    if not isinstance(value, str) or not value:
        raise QuietHoursError(f"{where} must be an IANA time zone name")
    try:
        return ZoneInfo(value)
    except (ZoneInfoNotFoundError, ValueError) as error:
        msg = f"{where}: unknown time zone `{value}`"
        raise QuietHoursError(msg) from error


def parse(table: object, where: str) -> QuietHours:
    """Build quiet hours from a `[quiet_hours]` table; `where` prefixes errors.

    `windows` is required, so a repo states its windows, even as `[]`;
    `timezone` is required once there is a window to place.
    """

    if not isinstance(table, dict):
        raise QuietHoursError(f"{where}: `quiet_hours` must be a table")
    raw = table.get("windows")
    if raw is None:
        raise QuietHoursError(f"{where}: `quiet_hours.windows` is required")
    if not isinstance(raw, list):
        raise QuietHoursError(f"{where}: `quiet_hours.windows` must be a list")
    if raw and "timezone" not in table:
        msg = f"{where}: `quiet_hours.timezone` is required with windows"
        raise QuietHoursError(msg)
    hours = QuietHours(
        _zone(table.get("timezone", "UTC"), f"{where}: `quiet_hours.timezone`"),
        tuple(
            _window(w, f"{where}: `quiet_hours.windows[{n}]`")
            for n, w in enumerate(raw)
        ),
    )
    if not hours.leaves_open_time():
        msg = f"{where}: `quiet_hours.windows` leave no open time in the week"
        raise QuietHoursError(msg)
    return hours
