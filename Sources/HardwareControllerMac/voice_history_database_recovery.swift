import Foundation
import SQLite3

/// Preserves a physically corrupt SQLite family before creating clean storage.
enum VoiceHistoryDatabaseRecovery {
  static func prepare(databaseURL: URL) throws -> String? {
    guard FileManager.default.fileExists(atPath: databaseURL.path) else {
      return nil
    }
    guard try databaseIsCorrupt(databaseURL) else {
      return nil
    }
    return try preserveDatabaseFamily(databaseURL)
  }

  private static func databaseIsCorrupt(_ url: URL) throws -> Bool {
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
      url.path,
      &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard openResult == SQLITE_OK, let database else {
      if let database {
        sqlite3_close(database)
      }
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not inspect its local database."
      )
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(
      database,
      "PRAGMA quick_check(1);",
      -1,
      &statement,
      nil
    )
    guard prepareResult == SQLITE_OK, let statement else {
      if let statement {
        sqlite3_finalize(statement)
      }
      if isCorruptionCode(prepareResult) || isCorruptionCode(sqlite3_errcode(database)) {
        return true
      }
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not inspect its local database."
      )
    }
    defer { sqlite3_finalize(statement) }
    let stepResult = sqlite3_step(statement)
    guard stepResult == SQLITE_ROW else {
      if isCorruptionCode(stepResult) || isCorruptionCode(sqlite3_errcode(database)) {
        return true
      }
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not inspect its local database."
      )
    }
    guard let result = sqlite3_column_text(statement, 0) else {
      return true
    }
    return String(cString: result) != "ok"
  }

  private static func preserveDatabaseFamily(_ databaseURL: URL) throws
    -> String
  {
    let identifier = UUID().uuidString
    let preservedFilename = "history_corrupt_\(identifier).sqlite3"
    let preservedURL = databaseURL.deletingLastPathComponent().appending(
      path: preservedFilename
    )
    let family: [(source: URL, destination: URL)] = [
      (
        sidecar(databaseURL, suffix: "-wal"),
        sidecar(preservedURL, suffix: "-wal")
      ),
      (
        sidecar(databaseURL, suffix: "-shm"),
        sidecar(preservedURL, suffix: "-shm")
      ),
      (databaseURL, preservedURL),
    ]
    var moved: [(source: URL, destination: URL)] = []
    do {
      for pair in family
      where FileManager.default.fileExists(atPath: pair.source.path) {
        try FileManager.default.moveItem(
          at: pair.source,
          to: pair.destination
        )
        moved.append(pair)
      }
      return preservedFilename
    } catch {
      for pair in moved.reversed() {
        try? FileManager.default.moveItem(
          at: pair.destination,
          to: pair.source
        )
      }
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not preserve its damaged local database."
      )
    }
  }

  private static func isCorruptionCode(_ code: Int32) -> Bool {
    let primaryCode = code & 0xFF
    return primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB
  }

  private static func sidecar(_ databaseURL: URL, suffix: String) -> URL {
    URL(fileURLWithPath: databaseURL.path + suffix)
  }
}
