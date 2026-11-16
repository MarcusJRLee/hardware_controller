import Foundation
import SQLite3
import Synchronization

@testable import HardwareControllerMac

/// Holds a Voice History database lock from a separate connection until the
/// connection under test reports, through its contention policy, that it is
/// waiting. The release runs inside that report on the waiter's own thread, so
/// the handoff never depends on how fast a runner schedules either side.
final class SQLiteTestWriteLock: Sendable {
  enum Strength: String {
    /// Blocks other writers; WAL readers proceed.
    case immediate = "BEGIN IMMEDIATE;"
    /// Also blocks readers of a rollback-journal database.
    case exclusive = "BEGIN EXCLUSIVE;"
  }

  private struct State {
    var database: OpaquePointer?
    var isReleased = false
    var waitCount = 0
    var releaseFailed = false
  }

  private let state = Mutex(State())

  /// Takes the lock; build the waiter's `contention()` first if it must exist
  /// before the lock does.
  func hold(databaseURL: URL, strength: Strength = .immediate) throws {
    // The connection is created inside the lock so it never leaves the
    // mutex's isolation region.
    try state.withLock { state in
      precondition(state.database == nil, "A test lock holds one database once.")
      var opened: OpaquePointer?
      guard sqlite3_open(databaseURL.path, &opened) == SQLITE_OK, let opened else {
        sqlite3_close(opened)
        throw VoiceSessionHistoryError.storageUnavailable(
          "The test database could not be opened."
        )
      }
      guard sqlite3_exec(opened, strength.rawValue, nil, nil, nil) == SQLITE_OK else {
        sqlite3_close(opened)
        throw VoiceSessionHistoryError.storageUnavailable(
          "The test database could not acquire its lock."
        )
      }
      state.database = opened
    }
  }

  /// A policy that releases this lock once the waiter has waited `after`.
  func contention(releasingAfter after: Duration = .zero) -> SQLiteVoiceHistoryContention {
    SQLiteVoiceHistoryContention { [self] waited in
      state.withLock { state in
        state.waitCount += 1
      }
      if waited >= after {
        release()
      }
    }
  }

  /// How many times a connection under test reported waiting on this lock.
  var waitCount: Int {
    state.withLock { $0.waitCount }
  }

  /// Whether a release reached the holder's COMMIT and SQLite refused it.
  var releaseFailed: Bool {
    state.withLock { $0.releaseFailed }
  }

  func release() {
    state.withLock { state in
      guard !state.isReleased, let database = state.database else {
        return
      }
      state.isReleased = true
      state.releaseFailed = sqlite3_exec(database, "COMMIT;", nil, nil, nil) != SQLITE_OK
    }
  }

  deinit {
    state.withLock { state in
      guard let database = state.database else {
        return
      }
      if !state.isReleased {
        sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
      }
      sqlite3_close(database)
    }
  }
}
