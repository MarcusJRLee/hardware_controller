import Dispatch

/// A condition never became true before the hang guard expired.
public struct ConditionTimeout: Error, CustomStringConvertible {
  public let description: String
}

/// Generous enough that only a hang, never a loaded runner, reaches it.
public let conditionHangGuard: Duration = .seconds(30)

/// `conditionHangGuard` from now, for blocking waits such as semaphores.
public func conditionHangGuardDeadline() -> DispatchTime {
  .now() + .seconds(Int(conditionHangGuard.components.seconds))
}

// Both overloads await the event itself; `timeout` only turns a hang into a
// failure and is never a speed assertion. Tests of deadlines use `ManualClock`.

/// Awaits a condition the caller's actor reads synchronously, without a hop.
public func waitUntil(
  _ description: String = "the awaited condition",
  timeout: Duration = conditionHangGuard,
  isolation: isolated (any Actor)? = #isolation,
  _ condition: () throws -> Bool
) async throws {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while !(try condition()) {
    try await pause(until: deadline, description)
  }
}

/// Awaits a condition that must itself await, such as another actor's state.
public func waitUntil(
  _ description: String = "the awaited condition",
  timeout: Duration = conditionHangGuard,
  isolation: isolated (any Actor)? = #isolation,
  _ condition: () async throws -> Bool
) async throws {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while !(try await condition()) {
    try await pause(until: deadline, description)
  }
}

private func pause(
  until deadline: ContinuousClock.Instant,
  _ description: String,
  isolation: isolated (any Actor)? = #isolation
) async throws {
  guard ContinuousClock.now < deadline else {
    throw ConditionTimeout(description: "Timed out waiting for \(description).")
  }
  try await Task.sleep(for: .milliseconds(5))
}
