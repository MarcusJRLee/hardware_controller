import Foundation
import HardwareControllerCore
import SQLite3

private final class SQLiteDatabaseHandle: @unchecked Sendable {
  let pointer: OpaquePointer

  init(_ pointer: OpaquePointer) {
    self.pointer = pointer
  }

  deinit {
    sqlite3_close(pointer)
  }
}

/// Owns the single serialized SQLite connection for Voice session metadata.
actor SQLiteVoiceSessionStore {
  /// SQLite uses the -1 sentinel to copy bound text before Swift releases it.
  private static let transientDestructor = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
  )

  private let handle: SQLiteDatabaseHandle
  private let audioDirectory: URL

  private var database: OpaquePointer { handle.pointer }

  init(databaseURL: URL, audioDirectory: URL) throws {
    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      databaseURL.path,
      &opened,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard result == SQLITE_OK, let opened else {
      if let opened {
        sqlite3_close(opened)
      }
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not open its local database."
      )
    }
    handle = SQLiteDatabaseHandle(opened)
    self.audioDirectory = audioDirectory
    try Self.execute(
      opened,
      sql: """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = FULL;
        CREATE TABLE IF NOT EXISTS voice_sessions (
          id TEXT PRIMARY KEY NOT NULL,
          started_at REAL NOT NULL,
          ended_at REAL NOT NULL,
          raw_text TEXT NOT NULL,
          edited_text TEXT NOT NULL,
          formatted_text TEXT NOT NULL,
          delivered_text TEXT NOT NULL,
          target_application_name TEXT,
          delivery_outcome TEXT NOT NULL,
          delivery_failure TEXT,
          audio_filename TEXT
        );
        CREATE INDEX IF NOT EXISTS voice_sessions_ended_at
        ON voice_sessions(ended_at DESC);
        """
    )
  }

  func insert(
    _ document: VoiceSessionDocument,
    audioURL: URL?
  ) throws {
    try Self.execute(database, sql: "BEGIN IMMEDIATE;")
    do {
      let sql = """
        INSERT INTO voice_sessions (
          id, started_at, ended_at, raw_text, edited_text,
          formatted_text, delivered_text, target_application_name,
          delivery_outcome, delivery_failure, audio_filename
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
        throw storageFailure()
      }
      defer { sqlite3_finalize(statement) }

      try bind(document.id.uuidString, to: 1, in: statement)
      sqlite3_bind_double(statement, 2, document.startedAt.timeIntervalSince1970)
      sqlite3_bind_double(statement, 3, document.endedAt.timeIntervalSince1970)
      try bind(document.rawText, to: 4, in: statement)
      try bind(document.editedText, to: 5, in: statement)
      try bind(document.formattedText, to: 6, in: statement)
      try bind(document.deliveredText, to: 7, in: statement)
      try bind(document.targetApplicationName, to: 8, in: statement)
      try bind(document.deliveryOutcome.rawValue, to: 9, in: statement)
      try bind(document.deliveryFailure, to: 10, in: statement)
      try bind(audioURL?.lastPathComponent, to: 11, in: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw storageFailure()
      }
      try Self.execute(database, sql: "COMMIT;")
    } catch {
      try? Self.execute(database, sql: "ROLLBACK;")
      throw error
    }
  }

  func recentSessions(limit: Int) throws -> [VoiceSessionHistoryItem] {
    guard (1...1_000).contains(limit) else {
      throw VoiceSessionHistoryError.invalidLimit
    }
    let sql = """
      SELECT id, started_at, ended_at, raw_text, edited_text,
        formatted_text, delivered_text, target_application_name,
        delivery_outcome, delivery_failure, audio_filename
      FROM voice_sessions
      ORDER BY ended_at DESC
      LIMIT ?;
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw storageFailure()
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int(statement, 1, Int32(limit))

    var items: [VoiceSessionHistoryItem] = []
    while true {
      let result = sqlite3_step(statement)
      guard result != SQLITE_DONE else {
        return items
      }
      guard result == SQLITE_ROW else {
        throw storageFailure()
      }
      guard
        let id = UUID(uuidString: text(statement, column: 0)),
        let outcome = VoiceSessionDeliveryOutcome(
          rawValue: text(statement, column: 8)
        )
      else {
        throw VoiceSessionHistoryError.storageUnavailable(
          "Voice History contains an invalid session record."
        )
      }
      let document = VoiceSessionDocument(
        id: id,
        startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
        endedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
        rawText: text(statement, column: 3),
        editedText: text(statement, column: 4),
        formattedText: text(statement, column: 5),
        deliveredText: text(statement, column: 6),
        targetApplicationName: optionalText(statement, column: 7),
        deliveryOutcome: outcome,
        deliveryFailure: optionalText(statement, column: 9)
      )
      let audioFilename = optionalText(statement, column: 10)
      let expectedAudioFilename = "\(id.uuidString).caf"
      guard
        audioFilename == nil || audioFilename == expectedAudioFilename
      else {
        throw VoiceSessionHistoryError.storageUnavailable(
          "Voice History contains an invalid audio reference."
        )
      }
      let audioURL = audioFilename.map {
        audioDirectory.appending(path: $0)
      }
      items.append(
        VoiceSessionHistoryItem(
          document: document,
          audioArtifactURL: audioURL
        )
      )
    }
  }

  private func bind(
    _ value: String?,
    to index: Int32,
    in statement: OpaquePointer
  ) throws {
    let result: Int32
    if let value {
      result = sqlite3_bind_text(
        statement,
        index,
        value,
        -1,
        Self.transientDestructor
      )
    } else {
      result = sqlite3_bind_null(statement, index)
    }
    guard result == SQLITE_OK else {
      throw storageFailure()
    }
  }

  private func text(
    _ statement: OpaquePointer,
    column: Int32
  ) -> String {
    guard let value = sqlite3_column_text(statement, column) else {
      return ""
    }
    return String(cString: value)
  }

  private func optionalText(
    _ statement: OpaquePointer,
    column: Int32
  ) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
      return nil
    }
    return text(statement, column: column)
  }

  private func storageFailure() -> VoiceSessionHistoryError {
    .storageUnavailable(
      "Voice History could not update its local database."
    )
  }

  private static func execute(
    _ database: OpaquePointer,
    sql: String
  ) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not prepare its local database."
      )
    }
  }
}
