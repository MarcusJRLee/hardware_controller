import Foundation
import SQLite3

/// How every Voice History connection waits out another connection's lock.
///
/// It installs SQLite's own `sqlite3_busy_timeout` backoff through
/// `sqlite3_busy_handler`, so production waits exactly as the built-in handler
/// would, and reports each wait to `willWait` on the waiting thread. Tests
/// release a held lock from that report instead of racing a timer against a
/// waiter that may not have started.
final class SQLiteVoiceHistoryContention: Sendable {
  /// Bounds transient writer contention outside the input-to-action hot path.
  static let timeoutMilliseconds = 5_000
  static let standard = SQLiteVoiceHistoryContention()

  /// SQLite's `sqlite3_busy_timeout` schedule; later retries repeat the last.
  private static let delaysMilliseconds = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100]

  private let willWait: @Sendable (_ waited: Duration) -> Void

  /// `willWait` receives the time already spent waiting in this busy episode.
  init(willWait: @escaping @Sendable (_ waited: Duration) -> Void = { _ in }) {
    self.willWait = willWait
  }

  /// SQLite keeps an unretained pointer to `self`, so the caller must keep this
  /// instance alive until the connection closes.
  func install(on database: OpaquePointer) -> Bool {
    sqlite3_busy_handler(
      database,
      { context, attempt in
        guard let context else {
          return 0
        }
        let contention = Unmanaged<SQLiteVoiceHistoryContention>
          .fromOpaque(context)
          .takeUnretainedValue()
        return contention.waitBeforeRetry(attempt: Int(attempt)) ? 1 : 0
      },
      Unmanaged.passUnretained(self).toOpaque()
    ) == SQLITE_OK
  }

  /// Returns the time already waited and the next sleep before retry
  /// `attempt` (zero-based), or nil once the bound is spent.
  static func backoff(
    attempt: Int,
    timeoutMilliseconds: Int = timeoutMilliseconds
  ) -> (waitedMilliseconds: Int, delayMilliseconds: Int)? {
    guard attempt >= 0 else {
      return nil
    }
    let scheduled = delaysMilliseconds.count
    let delay: Int
    let waited: Int
    if attempt < scheduled {
      delay = delaysMilliseconds[attempt]
      waited = delaysMilliseconds[..<attempt].reduce(0, +)
    } else {
      delay = delaysMilliseconds[scheduled - 1]
      // SQLite counts attempts in Int32, so this cannot overflow a 64-bit Int.
      waited =
        delaysMilliseconds[..<(scheduled - 1)].reduce(0, +)
        + (attempt - (scheduled - 1)) * delay
    }
    let remaining = timeoutMilliseconds - min(waited, timeoutMilliseconds)
    guard remaining > 0 else {
      return nil
    }
    return (waited, min(delay, remaining))
  }

  private func waitBeforeRetry(attempt: Int) -> Bool {
    guard let backoff = Self.backoff(attempt: attempt) else {
      return false
    }
    willWait(.milliseconds(backoff.waitedMilliseconds))
    sqlite3_sleep(Int32(backoff.delayMilliseconds))
    return true
  }
}

/// Owns one Voice History connection and the contention policy its busy
/// handler points at, so the policy outlives the connection's close. The
/// pointer never changes and every connection opens with
/// `SQLITE_OPEN_FULLMUTEX`, which serializes its use across threads.
final class SQLiteVoiceHistoryDatabaseHandle: @unchecked Sendable {
  let pointer: OpaquePointer
  private let contention: SQLiteVoiceHistoryContention

  init(_ pointer: OpaquePointer, contention: SQLiteVoiceHistoryContention) {
    self.pointer = pointer
    self.contention = contention
  }

  /// Installs the contention policy on the owned connection.
  func coordinate() -> Bool {
    contention.install(on: pointer)
  }

  deinit {
    sqlite3_close(pointer)
  }
}
