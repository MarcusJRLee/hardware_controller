/// A condition never became true before the hang guard expired.
public struct ConditionTimeout: Error, CustomStringConvertible {
  public let description: String
}

/// Generous enough that only a hang, never a loaded runner, reaches it.
public let conditionHangGuard: Duration = .seconds(30)

/// Awaits an asynchronously published condition.
///
/// This awaits the event itself; `timeout` only turns a hang into a failure
/// and is never a speed assertion. Tests of deadlines use `ManualClock`.
public func waitUntil(
  _ description: String = "the awaited condition",
  timeout: Duration = conditionHangGuard,
  isolation: isolated (any Actor)? = #isolation,
  _ condition: () async throws -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !(try await condition()) {
    guard clock.now < deadline else {
      throw ConditionTimeout(description: "Timed out waiting for \(description).")
    }
    try await Task.sleep(for: .milliseconds(5))
  }
}
