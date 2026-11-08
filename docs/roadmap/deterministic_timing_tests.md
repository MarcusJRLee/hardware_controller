---
title: Tests never depend on wall-clock timing
priority: P2
rank: i
executor: agent
depends_on: []
specs: [scripts/check.sh]
---

## Outcome

`swift test` passes or fails on behavior alone, never on how fast a loaded
machine runs it. Tests of deadlines, timeouts, or ordering drive an injected
clock or await the event itself, rather than sleeping for real time or bounding
real elapsed time.

Swift Testing runs the roughly 640 tests in parallel, and the CI runner has
three cores, so real sleeps and elapsed-time bounds can stretch by seconds. In
the last 100 CI runs, three timing tests failed this way and passed on re-run:

- `hungDecodeIsKilledAtTheDeadline` took 2.11 s against a 2 s bound, with a
  100 ms deadline. `TranscribeCppSpeechEngine` already takes a `clock`, but the
  test fixture passes the real one.
- `nonCooperativeLateResultCannotDelayOrDuplicateFallback` races a 10 ms
  refinement timeout against a 1 s delay.
- `applicationWindowTitleFollowsNavigation`.

About 25 other test sites sleep for real time; each needs a look.

## Acceptance

- No test bounds real elapsed time or sleeps for real time to order events. Each
  such site uses an injected clock or awaits the event, or says in a comment why
  real time is what it tests, as the opt-in performance and hardware suites do.
- The three tests above use an injected clock.
- `swift test` passes 20 runs in a row with every core busy (for example one
  `yes > /dev/null` per core).
