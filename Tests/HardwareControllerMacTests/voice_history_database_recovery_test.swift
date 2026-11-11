import Foundation
import SQLite3
import Testing

@testable import HardwareControllerMac

struct VoiceHistoryDatabaseRecoveryTest {
  private let directory = FileManager.default.temporaryDirectory.appending(
    path: "voice_history_database_recovery_\(UUID().uuidString)"
  )

  private var databaseURL: URL { directory.appending(path: "history.sqlite3") }

  private func makeDirectory() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private func contents() throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
  }

  /// A missing database needs no recovery and creates nothing.
  @Test
  func missingDatabaseIsLeftAlone() throws {
    try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try VoiceHistoryDatabaseRecovery.prepare(databaseURL: databaseURL) == nil)
    #expect(try contents().isEmpty)
  }

  /// A healthy database is never moved.
  @Test
  func healthyDatabaseIsLeftInPlace() throws {
    try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    #expect(sqlite3_exec(database, "CREATE TABLE t (x INTEGER);", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)

    #expect(try VoiceHistoryDatabaseRecovery.prepare(databaseURL: databaseURL) == nil)
    #expect(try contents() == ["history.sqlite3"])
  }

  /// A corrupt database and its sidecars move together under one unique name.
  @Test
  func corruptDatabaseFamilyIsPreservedTogether() throws {
    try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let garbage = Data(repeating: 0xA5, count: 8_192)
    try garbage.write(to: databaseURL)
    try Data("wal".utf8).write(to: URL(fileURLWithPath: databaseURL.path + "-wal"))

    let preserved = try #require(
      try VoiceHistoryDatabaseRecovery.prepare(databaseURL: databaseURL)
    )

    #expect(preserved.hasPrefix("history_corrupt_") && preserved.hasSuffix(".sqlite3"))
    // Opening a database beside a WAL makes SQLite create `-shm`; it moves too.
    let remaining = try contents()
    #expect(remaining.allSatisfy { $0.hasPrefix(preserved) })
    #expect(remaining.isSuperset(of: [preserved, preserved + "-wal"]))
    #expect(try Data(contentsOf: directory.appending(path: preserved)) == garbage)
  }

  /// Another connection's lock delays inspection instead of failing startup.
  @Test
  func lockedDatabaseIsInspectedOnceTheHolderReleases() async throws {
    try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var holder: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &holder) == SQLITE_OK)
    defer { sqlite3_close(holder) }
    #expect(
      sqlite3_exec(holder, "CREATE TABLE t (x INTEGER); BEGIN EXCLUSIVE;", nil, nil, nil)
        == SQLITE_OK
    )
    let databaseURL = databaseURL
    let inspection = Task.detached {
      try VoiceHistoryDatabaseRecovery.prepare(databaseURL: databaseURL)
    }
    // SQLite's busy handler waits on real time, which is what this tests. The
    // hold is far below the coordination timeout, so a stalled runner only
    // releases later (or before inspection starts) and never fails the test.
    try await Task.sleep(for: .milliseconds(100))
    #expect(sqlite3_exec(holder, "COMMIT;", nil, nil, nil) == SQLITE_OK)

    #expect(try await inspection.value == nil)
  }
}
