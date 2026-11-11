import Synchronization

/// A clock whose time moves only when a test advances it.
///
/// Deadlines, timeouts, and idle timers under test sleep on this clock, so a
/// loaded machine changes how long a test takes but never what it observes.
public final class ManualClock: Clock, Sendable {
  public struct Instant: InstantProtocol {
    fileprivate let offset: Duration

    public func advanced(by duration: Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    public func duration(to other: Instant) -> Duration {
      other.offset - offset
    }

    public static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.offset < rhs.offset
    }
  }

  /// One sleep's lifecycle; a finished sleep has no entry.
  private enum Sleep {
    /// Allocated, but its continuation is not stored yet.
    case registering
    /// Cancelled before its continuation was stored.
    case cancelledWhileRegistering
    case pending(deadline: Instant, continuation: CheckedContinuation<Void, any Error>)

    var deadline: Instant? {
      guard case .pending(let deadline, _) = self else {
        return nil
      }
      return deadline
    }
  }

  private struct SleeperWaiter {
    let horizon: Instant
    let continuation: CheckedContinuation<Void, Never>
  }

  private struct State {
    var now = Instant(offset: .zero)
    var nextID = 0
    var sleeps: [Int: Sleep] = [:]
    var sleeperWaiters: [SleeperWaiter] = []

    var earliestDeadline: Instant? {
      sleeps.values.compactMap(\.deadline).min()
    }
  }

  private enum Registration {
    case cancelled
    case elapsed
    /// Holds `waitForSleeper` callers this registration satisfied.
    case pending([CheckedContinuation<Void, Never>])
  }

  private let state = Mutex(State())

  public init() {}

  public var now: Instant {
    state.withLock { $0.now }
  }

  public var minimumResolution: Duration { .zero }

  /// Sleeps still waiting; zero proves no timer can fire on a later advance.
  public var pendingSleepers: Int {
    state.withLock { state in
      state.sleeps.values.count { $0.deadline != nil }
    }
  }

  public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
    try Task.checkCancellation()
    let id = state.withLock { state in
      defer { state.nextID += 1 }
      state.sleeps[state.nextID] = .registering
      return state.nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let registration = state.withLock { state -> Registration in
          guard case .registering = state.sleeps[id] else {
            state.sleeps[id] = nil
            return .cancelled
          }
          guard state.now < deadline else {
            state.sleeps[id] = nil
            return .elapsed
          }
          state.sleeps[id] = .pending(deadline: deadline, continuation: continuation)
          return .pending(Self.takeSatisfiedWaiters(&state))
        }
        switch registration {
        case .cancelled:
          continuation.resume(throwing: CancellationError())
        case .elapsed:
          continuation.resume()
        case .pending(let waiters):
          for waiter in waiters {
            waiter.resume()
          }
        }
      }
    } onCancel: {
      let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
        switch state.sleeps[id] {
        case .registering:
          state.sleeps[id] = .cancelledWhileRegistering
          return nil
        case .pending(_, let continuation):
          state.sleeps[id] = nil
          return continuation
        case .cancelledWhileRegistering, nil:
          return nil
        }
      }
      continuation?.resume(throwing: CancellationError())
    }
  }

  /// Moves time forward and wakes every sleep whose deadline has passed.
  public func advance(by duration: Duration) {
    precondition(duration >= .zero, "A manual clock never moves backwards.")
    let due = state.withLock { state in
      state.now = state.now.advanced(by: duration)
      let now = state.now
      var due: [(deadline: Instant, continuation: CheckedContinuation<Void, any Error>)] = []
      for (id, sleep) in state.sleeps {
        guard case .pending(let deadline, let continuation) = sleep, deadline <= now else {
          continue
        }
        state.sleeps[id] = nil
        due.append((deadline, continuation))
      }
      return due.sorted { $0.deadline < $1.deadline }
    }
    for sleep in due {
      sleep.continuation.resume()
    }
  }

  /// Returns once a pending sleep would wake within `duration` from now.
  ///
  /// Tests await this instead of sleeping so they advance time only after the
  /// timer they mean has started, whatever other timers are pending.
  public func waitForSleeper(dueWithin duration: Duration) async {
    await withCheckedContinuation { continuation in
      let isSatisfied = state.withLock { state in
        let horizon = state.now.advanced(by: duration)
        if let earliest = state.earliestDeadline, earliest <= horizon {
          return true
        }
        state.sleeperWaiters.append(SleeperWaiter(horizon: horizon, continuation: continuation))
        return false
      }
      if isSatisfied {
        continuation.resume()
      }
    }
  }

  private static func takeSatisfiedWaiters(_ state: inout State)
    -> [CheckedContinuation<Void, Never>]
  {
    guard let earliest = state.earliestDeadline else {
      return []
    }
    let waiters = state.sleeperWaiters
    state.sleeperWaiters = waiters.filter { earliest > $0.horizon }
    return waiters.filter { earliest <= $0.horizon }.map(\.continuation)
  }
}
