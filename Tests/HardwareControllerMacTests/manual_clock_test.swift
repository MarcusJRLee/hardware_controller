import HardwareControllerTestSupport
import Testing

struct ManualClockTest {
  @Test
  func sleepWakesOnlyOnceTimeReachesItsDeadline() async throws {
    let clock = ManualClock()
    let start = clock.now
    let sleep = Task { try await clock.sleep(for: .seconds(2)) }

    await clock.waitForSleeper(dueWithin: .seconds(2))
    clock.advance(by: .seconds(1))
    #expect(clock.pendingSleepers == 1)
    clock.advance(by: .seconds(1))

    try await sleep.value
    #expect(clock.pendingSleepers == 0)
    #expect(start.duration(to: clock.now) == .seconds(2))
  }

  @Test
  func waitingForASleeperIgnoresLaterTimers() async throws {
    let clock = ManualClock()
    let late = Task { try await clock.sleep(for: .seconds(60)) }
    await clock.waitForSleeper(dueWithin: .seconds(60))
    let soon = Task { try await clock.sleep(for: .milliseconds(10)) }

    await clock.waitForSleeper(dueWithin: .milliseconds(10))
    clock.advance(by: .milliseconds(10))

    try await soon.value
    #expect(clock.pendingSleepers == 1)
    late.cancel()
    await #expect(throws: CancellationError.self) { try await late.value }
  }

  @Test
  func cancellationBeforeOrDuringSleepThrowsAndClearsTheTimer() async throws {
    let clock = ManualClock()
    let cancelledFirst = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await clock.sleep(for: .seconds(1))
    }
    await #expect(throws: CancellationError.self) { try await cancelledFirst.value }

    let pending = Task { try await clock.sleep(for: .seconds(1)) }
    await clock.waitForSleeper(dueWithin: .seconds(1))
    pending.cancel()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(clock.pendingSleepers == 0)
  }

  @Test
  func elapsedDeadlineReturnsWithoutWaiting() async throws {
    let clock = ManualClock()
    clock.advance(by: .seconds(5))

    try await clock.sleep(until: clock.now.advanced(by: .seconds(-1)))
    try await clock.sleep(for: .zero)
    #expect(clock.pendingSleepers == 0)
  }
}
