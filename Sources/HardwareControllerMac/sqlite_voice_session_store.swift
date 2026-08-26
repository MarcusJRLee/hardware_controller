@preconcurrency import AVFoundation
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

struct SQLiteVoiceHistoryRecoveryDescriptor: Sendable {
  let id: UUID
  let audioFilename: String?
  let audioExpirationReason: VoiceHistoryAudioExpirationReason?
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
  private var didBackfillResults = false
  private var invalidSessionRecordCount = 0

  private var database: OpaquePointer { handle.pointer }

  init(
    databaseURL: URL,
    audioDirectory: URL
  ) throws {
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
    guard sqlite3_busy_timeout(opened, 2_000) == SQLITE_OK else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not configure database coordination."
      )
    }
    try Self.execute(
      opened,
      sql: """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = FULL;
        PRAGMA foreign_keys = ON;
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
          audio_filename TEXT,
          formatted_document_json TEXT,
          spoken_edits_json TEXT,
          delivery_failure_reason TEXT,
          audio_duration_ms INTEGER,
          is_pinned INTEGER NOT NULL DEFAULT 0,
          audio_expired_at REAL,
          audio_expiration_reason TEXT,
          recovery_kind TEXT,
          recovered_at REAL
        );
        CREATE TABLE IF NOT EXISTS voice_results (
          id TEXT PRIMARY KEY NOT NULL,
          session_id TEXT NOT NULL REFERENCES voice_sessions(id)
            ON DELETE CASCADE,
          created_at REAL NOT NULL,
          stage TEXT NOT NULL,
          origin TEXT NOT NULL,
          text TEXT NOT NULL,
          source_result_id TEXT REFERENCES voice_results(id),
          style_kind TEXT,
          style_revision INTEGER,
          provider TEXT,
          model_identifier TEXT,
          prompt_revision INTEGER,
          formatted_document_json TEXT,
          timed_spans_json TEXT,
          delivery_outcome TEXT,
          delivery_failure TEXT,
          delivery_failure_reason TEXT
        );
        CREATE INDEX IF NOT EXISTS voice_sessions_ended_at
        ON voice_sessions(ended_at DESC);
        CREATE INDEX IF NOT EXISTS voice_results_session
        ON voice_results(session_id, created_at);
        CREATE INDEX IF NOT EXISTS voice_results_source
        ON voice_results(source_result_id);
        """
    )
    try Self.addColumnIfNeeded(
      opened,
      name: "formatted_document_json",
      definition: "TEXT"
    )
    try Self.addColumnIfNeeded(
      opened,
      name: "spoken_edits_json",
      definition: "TEXT"
    )
    try Self.addColumnIfNeeded(
      opened,
      name: "delivery_failure_reason",
      definition: "TEXT"
    )
    try Self.addColumnIfNeeded(
      opened,
      name: "audio_duration_ms",
      definition: "INTEGER"
    )
    try Self.addColumnIfNeeded(
      opened,
      name: "is_pinned",
      definition: "INTEGER NOT NULL DEFAULT 0"
    )
    try Self.addColumnIfNeeded(
      opened,
      name: "audio_expired_at",
      definition: "REAL"
    )
    try Self.addColumnIfNeeded(
      opened,
      name: "audio_expiration_reason",
      definition: "TEXT"
    )
    try Self.addColumnIfNeeded(
      opened,
      name: "recovery_kind",
      definition: "TEXT"
    )
    try Self.addColumnIfNeeded(
      opened,
      name: "recovered_at",
      definition: "REAL"
    )
    try Self.addColumnIfNeeded(
      opened,
      table: "voice_results",
      name: "delivery_outcome",
      definition: "TEXT"
    )
    try Self.addColumnIfNeeded(
      opened,
      table: "voice_results",
      name: "delivery_failure",
      definition: "TEXT"
    )
    try Self.addColumnIfNeeded(
      opened,
      table: "voice_results",
      name: "delivery_failure_reason",
      definition: "TEXT"
    )
  }

  func insert(
    _ document: VoiceSessionDocument,
    audioURL: URL?,
    recoveryKind: VoiceHistoryRecoveryKind? = nil,
    recoveredAt: Date? = nil
  ) throws {
    try ensureResultsBackfilled()
    try validateDeliveryEvidence(document)
    let audioDurationMilliseconds = try audioDurationMilliseconds(
      at: audioURL
    )
    try Self.execute(database, sql: "BEGIN IMMEDIATE;")
    do {
      let sql = """
        INSERT INTO voice_sessions (
          id, started_at, ended_at, raw_text, edited_text,
          formatted_text, delivered_text, target_application_name,
          delivery_outcome, delivery_failure, audio_filename,
          formatted_document_json, spoken_edits_json,
          delivery_failure_reason, audio_duration_ms, is_pinned,
          recovery_kind, recovered_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?);
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
      let formattedDocumentJSON = try encodedFormattedDocument(
        document.formattedDocument,
        expectedRawText: document.rawText,
        expectedFormattedText: document.formattedText
      )
      try bind(formattedDocumentJSON, to: 12, in: statement)
      let spokenEditsJSON = try encodedSpokenEdits(
        document.spokenEdits
      )
      try bind(spokenEditsJSON, to: 13, in: statement)
      try bind(
        document.deliveryFailureReason?.rawValue,
        to: 14,
        in: statement
      )
      if let audioDurationMilliseconds {
        sqlite3_bind_int64(
          statement,
          15,
          audioDurationMilliseconds
        )
      } else {
        sqlite3_bind_null(statement, 15)
      }
      try bind(recoveryKind?.rawValue, to: 16, in: statement)
      if let recoveredAt {
        sqlite3_bind_double(statement, 17, recoveredAt.timeIntervalSince1970)
      } else {
        sqlite3_bind_null(statement, 17)
      }
      guard (recoveryKind == nil) == (recoveredAt == nil) else {
        throw VoiceSessionHistoryError.storageUnavailable(
          "Voice History contains incomplete recovery evidence."
        )
      }
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw storageFailure()
      }
      for result in baselineResults(
        for: document,
        audioDurationMilliseconds: audioDurationMilliseconds
      ) {
        try insertResult(result)
      }
      try Self.execute(database, sql: "COMMIT;")
    } catch {
      try? Self.execute(database, sql: "ROLLBACK;")
      throw error
    }
  }

  func insertRecoveredSession(
    id: UUID,
    audioURL: URL,
    kind: VoiceHistoryRecoveryKind,
    recoveredAt: Date,
    artifactModifiedAt: Date
  ) throws {
    let endedAt = min(artifactModifiedAt, recoveredAt)
    let startedAt = endedAt.addingTimeInterval(-1)
    try insert(
      VoiceSessionDocument(
        id: id,
        startedAt: startedAt,
        endedAt: endedAt,
        rawText: "",
        editedText: "",
        formattedText: "",
        deliveredText: "",
        targetApplicationName: nil,
        deliveryOutcome: .notAttempted
      ),
      audioURL: audioURL,
      recoveryKind: kind,
      recoveredAt: recoveredAt
    )
  }

  func recoveryDescriptors() throws
    -> [SQLiteVoiceHistoryRecoveryDescriptor]
  {
    let sql = """
      SELECT id, audio_filename, audio_expiration_reason
      FROM voice_sessions
      ORDER BY id ASC;
      """
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw storageFailure()
    }
    defer { sqlite3_finalize(statement) }
    var descriptors: [SQLiteVoiceHistoryRecoveryDescriptor] = []
    while true {
      let result = sqlite3_step(statement)
      guard result != SQLITE_DONE else {
        return descriptors
      }
      guard result == SQLITE_ROW else {
        throw storageFailure()
      }
      guard let id = UUID(uuidString: text(statement, column: 0)) else {
        invalidSessionRecordCount += 1
        continue
      }
      do {
        descriptors.append(
          SQLiteVoiceHistoryRecoveryDescriptor(
            id: id,
            audioFilename: optionalText(statement, column: 1),
            audioExpirationReason: try optionalAudioExpirationReason(
              optionalText(statement, column: 2)
            )
          )
        )
      } catch {
        invalidSessionRecordCount += 1
      }
    }
  }

  func consumeInvalidSessionRecordCount() -> Int {
    defer { invalidSessionRecordCount = 0 }
    return invalidSessionRecordCount
  }

  func recentSessions(limit: Int) throws -> [VoiceSessionHistoryItem] {
    try ensureResultsBackfilled()
    return try querySessions(
      predicate: nil,
      bindings: [],
      limit: limit
    )
  }

  func searchSessions(
    query: String,
    limit: Int
  ) throws -> [VoiceSessionHistoryItem] {
    try ensureResultsBackfilled()
    let normalized = query.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !normalized.isEmpty else {
      return try recentSessions(limit: limit)
    }
    let pattern = "%\(escapedLikePattern(normalized))%"
    return try querySessions(
      predicate: """
        EXISTS (
          SELECT 1 FROM voice_results AS search_result
          WHERE search_result.session_id = voice_sessions.id
            AND search_result.text LIKE ? ESCAPE '\\' COLLATE NOCASE
        )
        """,
      bindings: [pattern],
      limit: limit
    )
  }

  func session(id: UUID) throws -> VoiceSessionHistoryItem? {
    try ensureResultsBackfilled()
    return try querySessions(
      predicate: "voice_sessions.id = ?",
      bindings: [id.uuidString],
      limit: 1
    ).first
  }

  func appendResult(_ result: VoiceHistoryResult) throws {
    try ensureResultsBackfilled()
    try validateDerivedResult(result)
    try Self.execute(database, sql: "BEGIN IMMEDIATE;")
    do {
      guard try sessionExists(result.sessionID) else {
        throw VoiceSessionHistoryError.sessionNotFound
      }
      if let sourceResultID = result.sourceResultID {
        guard
          try resultBelongsToSession(
            id: sourceResultID,
            sessionID: result.sessionID
          )
        else {
          throw VoiceSessionHistoryError.invalidResult(
            "A History result must derive from the same Voice session."
          )
        }
      }
      try validateTiming(
        result,
        audioDurationMilliseconds: try storedAudioDuration(
          sessionID: result.sessionID
        )
      )
      try insertResult(result)
      try Self.execute(database, sql: "COMMIT;")
    } catch {
      try? Self.execute(database, sql: "ROLLBACK;")
      throw error
    }
  }

  func setPinned(
    sessionID: UUID,
    isPinned: Bool
  ) throws {
    try ensureResultsBackfilled()
    let sql = "UPDATE voice_sessions SET is_pinned = ? WHERE id = ?;"
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw storageFailure()
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int(statement, 1, isPinned ? 1 : 0)
    try bind(sessionID.uuidString, to: 2, in: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw storageFailure()
    }
    guard sqlite3_changes(database) == 1 else {
      throw VoiceSessionHistoryError.sessionNotFound
    }
  }

  func deleteSession(id: UUID) throws {
    try ensureResultsBackfilled()
    guard let item = try session(id: id) else {
      throw VoiceSessionHistoryError.sessionNotFound
    }
    let originalAudioURL = item.audioArtifactURL
    let quarantinedAudioURL = originalAudioURL.map { _ in
      audioDirectory.appending(
        path: ".deleting_\(id.uuidString).caf"
      )
    }
    if let originalAudioURL, let quarantinedAudioURL,
      FileManager.default.fileExists(atPath: originalAudioURL.path)
    {
      do {
        try FileManager.default.moveItem(
          at: originalAudioURL,
          to: quarantinedAudioURL
        )
      } catch {
        throw VoiceSessionHistoryError.storageUnavailable(
          "Voice History could not prepare the audio for deletion."
        )
      }
    }
    do {
      try Self.execute(database, sql: "BEGIN IMMEDIATE;")
      let sql = "DELETE FROM voice_sessions WHERE id = ?;"
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
        throw storageFailure()
      }
      try bind(id.uuidString, to: 1, in: statement)
      let result = sqlite3_step(statement)
      sqlite3_finalize(statement)
      guard result == SQLITE_DONE, sqlite3_changes(database) == 1 else {
        throw storageFailure()
      }
      try Self.execute(database, sql: "COMMIT;")
      if let quarantinedAudioURL {
        try? FileManager.default.removeItem(at: quarantinedAudioURL)
      }
    } catch {
      try? Self.execute(database, sql: "ROLLBACK;")
      if let originalAudioURL, let quarantinedAudioURL,
        FileManager.default.fileExists(atPath: quarantinedAudioURL.path)
      {
        try? FileManager.default.moveItem(
          at: quarantinedAudioURL,
          to: originalAudioURL
        )
      }
      throw error
    }
  }

  private func querySessions(
    predicate: String?,
    bindings: [String],
    limit: Int
  ) throws -> [VoiceSessionHistoryItem] {
    guard (1...1_000).contains(limit) else {
      throw VoiceSessionHistoryError.invalidLimit
    }
    let whereClause = predicate.map { "WHERE \($0)" } ?? ""
    let sql = """
      SELECT id, started_at, ended_at, raw_text, edited_text,
        formatted_text, delivered_text, target_application_name,
        delivery_outcome, delivery_failure, audio_filename,
        formatted_document_json, spoken_edits_json,
        delivery_failure_reason, audio_duration_ms, is_pinned,
        audio_expired_at, audio_expiration_reason, recovery_kind,
        recovered_at
      FROM voice_sessions
      \(whereClause)
      ORDER BY ended_at DESC;
      """
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw storageFailure()
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in bindings.enumerated() {
      try bind(value, to: Int32(offset + 1), in: statement)
    }
    var items: [VoiceSessionHistoryItem] = []
    while true {
      let result = sqlite3_step(statement)
      guard result != SQLITE_DONE else {
        return items
      }
      guard result == SQLITE_ROW else {
        throw storageFailure()
      }
      do {
        items.append(try historyItem(from: statement))
        if items.count == limit {
          return items
        }
      } catch {
        let code = sqlite3_errcode(database) & 0xFF
        guard code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE else {
          throw error
        }
        invalidSessionRecordCount += 1
      }
    }
  }

  private func historyItem(
    from statement: OpaquePointer
  ) throws -> VoiceSessionHistoryItem {
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
      startedAt: Date(
        timeIntervalSince1970: sqlite3_column_double(statement, 1)
      ),
      endedAt: Date(
        timeIntervalSince1970: sqlite3_column_double(statement, 2)
      ),
      rawText: text(statement, column: 3),
      editedText: text(statement, column: 4),
      formattedText: text(statement, column: 5),
      deliveredText: text(statement, column: 6),
      targetApplicationName: optionalText(statement, column: 7),
      deliveryOutcome: outcome,
      deliveryFailure: optionalText(statement, column: 9),
      deliveryFailureReason: try deliveryFailureReason(
        from: optionalText(statement, column: 13)
      ),
      formattedDocument: try formattedDocument(
        from: optionalText(statement, column: 11),
        expectedRawText: text(statement, column: 3),
        expectedFormattedText: text(statement, column: 5)
      ),
      spokenEdits: try spokenEdits(
        from: optionalText(statement, column: 12)
      )
    )
    try validateDeliveryEvidence(document)
    let audioFilename = optionalText(statement, column: 10)
    let expectedAudioFilename = "\(id.uuidString).caf"
    guard audioFilename == nil || audioFilename == expectedAudioFilename else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains an invalid audio reference."
      )
    }
    let duration = optionalInt64(statement, column: 14)
    let pinnedValue = sqlite3_column_int(statement, 15)
    let audioExpiredAt = optionalDouble(statement, column: 16).map {
      Date(timeIntervalSince1970: $0)
    }
    let audioExpirationReason = try optionalAudioExpirationReason(
      optionalText(statement, column: 17)
    )
    let recoveryKind = try optionalRecoveryKind(
      optionalText(statement, column: 18)
    )
    let recoveredAt = optionalDouble(statement, column: 19).map {
      Date(timeIntervalSince1970: $0)
    }
    guard
      duration.map({ $0 > 0 }) ?? true,
      pinnedValue == 0 || pinnedValue == 1,
      (audioExpiredAt == nil) == (audioExpirationReason == nil),
      audioFilename == nil || audioExpiredAt == nil,
      (recoveryKind == nil) == (recoveredAt == nil),
      recoveredAt.map({
        $0.timeIntervalSince1970.isFinite && $0 >= document.endedAt
      }) ?? true,
      audioExpiredAt.map({
        $0.timeIntervalSince1970.isFinite && $0 >= document.endedAt
      }) ?? true
    else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid archive metadata."
      )
    }
    let storedResults = try results(sessionID: id)
    for result in storedResults {
      try validateTiming(
        result,
        audioDurationMilliseconds: duration
      )
    }
    let storedAudioURL = audioFilename.map {
      audioDirectory.appending(path: $0)
    }
    let availableAudioURL = storedAudioURL.flatMap {
      FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
    }
    return VoiceSessionHistoryItem(
      document: document,
      audioArtifactURL: availableAudioURL,
      audioDurationMilliseconds: duration,
      audioExpiredAt: audioExpiredAt,
      audioExpirationReason: audioExpirationReason,
      recoveryKind: recoveryKind,
      recoveredAt: recoveredAt,
      isPinned: pinnedValue == 1,
      results: storedResults
    )
  }

  private func results(
    sessionID: UUID
  ) throws -> [VoiceHistoryResult] {
    let sql = """
      SELECT id, created_at, stage, origin, text, source_result_id,
        style_kind, style_revision, provider, model_identifier,
        prompt_revision, formatted_document_json, timed_spans_json,
        delivery_outcome, delivery_failure, delivery_failure_reason
      FROM voice_results
      WHERE session_id = ?
      ORDER BY rowid ASC;
      """
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw storageFailure()
    }
    defer { sqlite3_finalize(statement) }
    try bind(sessionID.uuidString, to: 1, in: statement)
    var results: [VoiceHistoryResult] = []
    var priorResultIDs: Set<UUID> = []
    while true {
      let step = sqlite3_step(statement)
      guard step != SQLITE_DONE else {
        return results
      }
      guard
        step == SQLITE_ROW,
        let id = UUID(uuidString: text(statement, column: 0)),
        let stage = VoiceHistoryTextStage(
          rawValue: text(statement, column: 2)
        ),
        let origin = VoiceHistoryResultOrigin(
          rawValue: text(statement, column: 3)
        )
      else {
        throw VoiceSessionHistoryError.storageUnavailable(
          "Voice History contains an invalid result record."
        )
      }
      let style = try historyStyle(
        kind: optionalText(statement, column: 6),
        revision: optionalInt(statement, column: 7)
      )
      let provider = try historyProvider(
        optionalText(statement, column: 8)
      )
      let result = VoiceHistoryResult(
        id: id,
        sessionID: sessionID,
        createdAt: Date(
          timeIntervalSince1970: sqlite3_column_double(statement, 1)
        ),
        stage: stage,
        origin: origin,
        text: text(statement, column: 4),
        sourceResultID: try optionalUUID(
          optionalText(statement, column: 5)
        ),
        style: style,
        provider: provider,
        modelIdentifier: optionalText(statement, column: 9),
        promptRevision: optionalInt(statement, column: 10),
        formattedDocument: try historyFormattedDocument(
          from: optionalText(statement, column: 11),
          expectedText: text(statement, column: 4)
        ),
        timedSpans: try timedSpans(
          from: optionalText(statement, column: 12)
        ),
        deliveryOutcome: try historyDeliveryOutcome(
          optionalText(statement, column: 13)
        ),
        deliveryFailure: optionalText(statement, column: 14),
        deliveryFailureReason: try deliveryFailureReason(
          from: optionalText(statement, column: 15)
        )
      )
      try validateStoredResult(result)
      try validateStoredRelationship(
        result,
        priorResultIDs: priorResultIDs
      )
      results.append(result)
      priorResultIDs.insert(result.id)
    }
  }

  private func baselineResults(
    for document: VoiceSessionDocument,
    audioDurationMilliseconds: Int64?
  ) -> [VoiceHistoryResult] {
    let rawID = UUID()
    let editedID = UUID()
    let formattedID = UUID()
    let evidence = document.formattedDocument?.evidence.first
    let rawSpans: [VoiceHistoryTimedSpan]
    if let audioDurationMilliseconds, !document.rawText.isEmpty {
      rawSpans = [
        VoiceHistoryTimedSpan(
          startMilliseconds: 0,
          endMilliseconds: audioDurationMilliseconds,
          text: document.rawText
        )
      ]
    } else {
      rawSpans = []
    }
    return [
      VoiceHistoryResult(
        id: rawID,
        sessionID: document.id,
        createdAt: document.endedAt,
        stage: .raw,
        origin: .capture,
        text: document.rawText,
        sourceResultID: nil,
        timedSpans: rawSpans
      ),
      VoiceHistoryResult(
        id: editedID,
        sessionID: document.id,
        createdAt: document.endedAt,
        stage: .edited,
        origin: .spokenEdits,
        text: document.editedText,
        sourceResultID: rawID
      ),
      VoiceHistoryResult(
        id: formattedID,
        sessionID: document.id,
        createdAt: document.endedAt,
        stage: .formatted,
        origin: .formatting,
        text: document.formattedText,
        sourceResultID: editedID,
        style: document.formattedDocument?.style,
        provider: evidence?.provider,
        modelIdentifier: evidence?.modelIdentifier,
        promptRevision: evidence?.promptRevision,
        formattedDocument: document.formattedDocument
      ),
      VoiceHistoryResult(
        sessionID: document.id,
        createdAt: document.endedAt,
        stage: .delivered,
        origin: .delivery,
        text: document.deliveredText,
        sourceResultID: formattedID,
        deliveryOutcome: document.deliveryOutcome,
        deliveryFailure: document.deliveryFailure,
        deliveryFailureReason: document.deliveryFailureReason
      ),
    ]
  }

  private func insertResult(_ result: VoiceHistoryResult) throws {
    try validateStoredResult(result)
    let sql = """
      INSERT INTO voice_results (
        id, session_id, created_at, stage, origin, text,
        source_result_id, style_kind, style_revision, provider,
        model_identifier, prompt_revision, formatted_document_json,
        timed_spans_json, delivery_outcome, delivery_failure,
        delivery_failure_reason
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw storageFailure()
    }
    defer { sqlite3_finalize(statement) }
    try bind(result.id.uuidString, to: 1, in: statement)
    try bind(result.sessionID.uuidString, to: 2, in: statement)
    sqlite3_bind_double(statement, 3, result.createdAt.timeIntervalSince1970)
    try bind(result.stage.rawValue, to: 4, in: statement)
    try bind(result.origin.rawValue, to: 5, in: statement)
    try bind(result.text, to: 6, in: statement)
    try bind(result.sourceResultID?.uuidString, to: 7, in: statement)
    try bind(result.style?.kind.rawValue, to: 8, in: statement)
    if let revision = result.style?.revision {
      sqlite3_bind_int64(statement, 9, Int64(revision))
    } else {
      sqlite3_bind_null(statement, 9)
    }
    try bind(result.provider?.rawValue, to: 10, in: statement)
    try bind(result.modelIdentifier, to: 11, in: statement)
    if let promptRevision = result.promptRevision {
      sqlite3_bind_int64(statement, 12, Int64(promptRevision))
    } else {
      sqlite3_bind_null(statement, 12)
    }
    try bind(
      try encodedHistoryFormattedDocument(result),
      to: 13,
      in: statement
    )
    try bind(try encodedTimedSpans(result.timedSpans), to: 14, in: statement)
    try bind(result.deliveryOutcome?.rawValue, to: 15, in: statement)
    try bind(result.deliveryFailure, to: 16, in: statement)
    try bind(
      result.deliveryFailureReason?.rawValue,
      to: 17,
      in: statement
    )
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw storageFailure()
    }
  }

  private func validateDerivedResult(
    _ result: VoiceHistoryResult
  ) throws {
    let validPair: (VoiceHistoryTextStage, VoiceHistoryResultOrigin)
    switch result.origin {
    case .correction:
      validPair = (.corrected, .correction)
    case .retranscription:
      validPair = (.raw, .retranscription)
    case .reformatting:
      validPair = (.formatted, .reformatting)
    case .redelivery:
      validPair = (.delivered, .redelivery)
    case .capture, .spokenEdits, .formatting, .delivery:
      throw VoiceSessionHistoryError.invalidResult(
        "Captured History stages can only be created during session finalization."
      )
    }
    guard
      result.stage == validPair.0,
      result.origin == validPair.1,
      result.sourceResultID != nil
    else {
      throw VoiceSessionHistoryError.invalidResult(
        "A derived History result has invalid stage evidence."
      )
    }
    if result.origin == .redelivery {
      guard
        result.deliveryOutcome == .inserted
          && !result.text.isEmpty
          && result.deliveryFailure == nil
          && result.deliveryFailureReason == nil
          || result.deliveryOutcome == .failed
            && result.text.isEmpty
            && result.deliveryFailure != nil
      else {
        throw VoiceSessionHistoryError.invalidResult(
          "A re-delivery result contains contradictory outcome evidence."
        )
      }
    } else {
      guard
        !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        result.deliveryOutcome == nil,
        result.deliveryFailure == nil,
        result.deliveryFailureReason == nil
      else {
        throw VoiceSessionHistoryError.invalidResult(
          "A derived History result contains invalid text evidence."
        )
      }
    }
    try validateStoredResult(result)
  }

  private func validateStoredResult(
    _ result: VoiceHistoryResult
  ) throws {
    let hasValidStageOrigin: Bool
    switch (result.stage, result.origin) {
    case (.raw, .capture),
      (.raw, .retranscription),
      (.edited, .spokenEdits),
      (.formatted, .formatting),
      (.formatted, .reformatting),
      (.delivered, .delivery),
      (.delivered, .redelivery),
      (.corrected, .correction):
      hasValidStageOrigin = true
    default:
      hasValidStageOrigin = false
    }
    guard hasValidStageOrigin else {
      throw VoiceSessionHistoryError.invalidResult(
        "History contains a result with contradictory stage provenance."
      )
    }
    let hasFormattingEvidence =
      result.style != nil
      || result.provider != nil
      || result.modelIdentifier != nil
      || result.promptRevision != nil
      || result.formattedDocument != nil
    guard !hasFormattingEvidence || result.stage == .formatted else {
      throw VoiceSessionHistoryError.invalidResult(
        "Only a Formatted result may carry formatting evidence."
      )
    }
    if let document = result.formattedDocument {
      let evidence = document.evidence.first
      guard
        result.style == document.style,
        result.provider == evidence?.provider,
        result.modelIdentifier == evidence?.modelIdentifier,
        result.promptRevision == evidence?.promptRevision
      else {
        throw VoiceSessionHistoryError.invalidResult(
          "History contains contradictory formatting provenance."
        )
      }
    }
    let hasDeliveryEvidence =
      result.deliveryOutcome != nil
      || result.deliveryFailure != nil
      || result.deliveryFailureReason != nil
    guard !hasDeliveryEvidence || result.stage == .delivered else {
      throw VoiceSessionHistoryError.invalidResult(
        "Only a Delivered result may carry delivery evidence."
      )
    }
    guard result.stage != .delivered || result.deliveryOutcome != nil else {
      throw VoiceSessionHistoryError.invalidResult(
        "A Delivered result must carry typed outcome evidence."
      )
    }
    if let outcome = result.deliveryOutcome {
      switch outcome {
      case .inserted:
        guard
          !result.text.isEmpty,
          result.deliveryFailure == nil,
          result.deliveryFailureReason == nil
        else {
          throw VoiceSessionHistoryError.invalidResult(
            "History contains contradictory successful delivery evidence."
          )
        }
      case .failed:
        guard result.text.isEmpty, result.deliveryFailure != nil else {
          throw VoiceSessionHistoryError.invalidResult(
            "History contains contradictory failed delivery evidence."
          )
        }
      case .notAttempted:
        guard
          result.text.isEmpty,
          result.deliveryFailure == nil,
          result.deliveryFailureReason == nil
        else {
          throw VoiceSessionHistoryError.invalidResult(
            "History contains contradictory delivery evidence."
          )
        }
      }
    }
    for span in result.timedSpans {
      guard
        result.stage == .raw,
        span.startMilliseconds >= 0,
        span.endMilliseconds > span.startMilliseconds,
        !span.text.isEmpty
      else {
        throw VoiceSessionHistoryError.invalidResult(
          "History contains an invalid timed transcript span."
        )
      }
    }
  }

  private func validateStoredRelationship(
    _ result: VoiceHistoryResult,
    priorResultIDs: Set<UUID>
  ) throws {
    if result.origin == .capture {
      guard result.sourceResultID == nil else {
        throw VoiceSessionHistoryError.invalidResult(
          "Captured History evidence cannot derive from another result."
        )
      }
      return
    }
    guard
      let sourceResultID = result.sourceResultID,
      priorResultIDs.contains(sourceResultID)
    else {
      throw VoiceSessionHistoryError.invalidResult(
        "History contains an invalid result relationship."
      )
    }
  }

  private func sessionExists(_ id: UUID) throws -> Bool {
    try scalarCount(
      sql: "SELECT COUNT(*) FROM voice_sessions WHERE id = ?;",
      bindings: [id.uuidString]
    ) == 1
  }

  private func storedAudioDuration(
    sessionID: UUID
  ) throws -> Int64? {
    let sql = "SELECT audio_duration_ms FROM voice_sessions WHERE id = ?;"
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw storageFailure()
    }
    defer { sqlite3_finalize(statement) }
    try bind(sessionID.uuidString, to: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw VoiceSessionHistoryError.sessionNotFound
    }
    return optionalInt64(statement, column: 0)
  }

  private func validateTiming(
    _ result: VoiceHistoryResult,
    audioDurationMilliseconds: Int64?
  ) throws {
    guard
      result.timedSpans.allSatisfy({ span in
        audioDurationMilliseconds.map {
          span.endMilliseconds <= $0
        } ?? false
      })
    else {
      throw VoiceSessionHistoryError.invalidResult(
        "A timed transcript span must stay within retained audio."
      )
    }
  }

  private func resultBelongsToSession(
    id: UUID,
    sessionID: UUID
  ) throws -> Bool {
    try scalarCount(
      sql: "SELECT COUNT(*) FROM voice_results WHERE id = ? AND session_id = ?;",
      bindings: [id.uuidString, sessionID.uuidString]
    ) == 1
  }

  private func scalarCount(
    sql: String,
    bindings: [String]
  ) throws -> Int {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw storageFailure()
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in bindings.enumerated() {
      try bind(value, to: Int32(offset + 1), in: statement)
    }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw storageFailure()
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func backfillMissingResults() throws {
    while let session = try querySessions(
      predicate: """
        NOT EXISTS (
          SELECT 1 FROM voice_results
          WHERE voice_results.session_id = voice_sessions.id
        )
        """,
      bindings: [],
      limit: 1
    ).first {
      let duration =
        try
        (session.audioDurationMilliseconds
        ?? audioDurationMilliseconds(at: session.audioArtifactURL))
      try Self.execute(database, sql: "BEGIN IMMEDIATE;")
      do {
        if session.audioDurationMilliseconds == nil, let duration {
          try updateAudioDuration(
            sessionID: session.id,
            milliseconds: duration
          )
        }
        for result in baselineResults(
          for: session.document,
          audioDurationMilliseconds: duration
        ) {
          try insertResult(result)
        }
        try Self.execute(database, sql: "COMMIT;")
      } catch {
        try? Self.execute(database, sql: "ROLLBACK;")
        throw error
      }
    }
  }

  private func ensureResultsBackfilled() throws {
    guard !didBackfillResults else {
      return
    }
    try backfillMissingResults()
    didBackfillResults = true
  }

  private func updateAudioDuration(
    sessionID: UUID,
    milliseconds: Int64
  ) throws {
    let sql = "UPDATE voice_sessions SET audio_duration_ms = ? WHERE id = ?;"
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw storageFailure()
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, milliseconds)
    try bind(sessionID.uuidString, to: 2, in: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw storageFailure()
    }
  }

  private func audioDurationMilliseconds(at url: URL?) throws -> Int64? {
    guard let url else {
      return nil
    }
    do {
      let file = try AVAudioFile(forReading: url)
      guard file.processingFormat.sampleRate > 0 else {
        throw VoiceSessionHistoryError.audioUnavailable(
          "Voice History contains audio with an invalid sample rate."
        )
      }
      return Int64(
        (Double(file.length) / file.processingFormat.sampleRate * 1_000)
          .rounded()
      )
    } catch let failure as VoiceSessionHistoryError {
      throw failure
    } catch {
      throw VoiceSessionHistoryError.audioUnavailable(
        "Voice History could not inspect the retained audio artifact."
      )
    }
  }

  private func escapedLikePattern(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
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

  private func optionalInt(
    _ statement: OpaquePointer,
    column: Int32
  ) -> Int? {
    optionalInt64(statement, column: column).map(Int.init)
  }

  private func optionalInt64(
    _ statement: OpaquePointer,
    column: Int32
  ) -> Int64? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
      return nil
    }
    return sqlite3_column_int64(statement, column)
  }

  private func optionalDouble(
    _ statement: OpaquePointer,
    column: Int32
  ) -> Double? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
      return nil
    }
    return sqlite3_column_double(statement, column)
  }

  private func optionalAudioExpirationReason(
    _ rawValue: String?
  ) throws -> VoiceHistoryAudioExpirationReason? {
    guard let rawValue else {
      return nil
    }
    guard let reason = VoiceHistoryAudioExpirationReason(rawValue: rawValue)
    else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains an invalid audio expiration reason."
      )
    }
    return reason
  }

  private func optionalRecoveryKind(
    _ rawValue: String?
  ) throws -> VoiceHistoryRecoveryKind? {
    guard let rawValue else {
      return nil
    }
    guard let kind = VoiceHistoryRecoveryKind(rawValue: rawValue) else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains an invalid recovery kind."
      )
    }
    return kind
  }

  private func optionalUUID(_ value: String?) throws -> UUID? {
    guard let value else {
      return nil
    }
    guard let id = UUID(uuidString: value) else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains an invalid result relationship."
      )
    }
    return id
  }

  private func historyStyle(
    kind: String?,
    revision: Int?
  ) throws -> VoiceStyle? {
    guard kind != nil || revision != nil else {
      return nil
    }
    guard
      let kind,
      let revision,
      let styleKind = VoiceStyleKind(rawValue: kind),
      revision > 0
    else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid Style evidence."
      )
    }
    return VoiceStyle(kind: styleKind, revision: revision)
  }

  private func historyProvider(
    _ value: String?
  ) throws -> LocalAIProviderKind? {
    guard let value else {
      return nil
    }
    guard let provider = LocalAIProviderKind(rawValue: value) else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid provider evidence."
      )
    }
    return provider
  }

  private func historyDeliveryOutcome(
    _ value: String?
  ) throws -> VoiceSessionDeliveryOutcome? {
    guard let value else {
      return nil
    }
    guard let outcome = VoiceSessionDeliveryOutcome(rawValue: value) else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid delivery-result evidence."
      )
    }
    return outcome
  }

  private func storageFailure() -> VoiceSessionHistoryError {
    .storageUnavailable(
      "Voice History could not update its local database."
    )
  }

  private func historyFormattedDocument(
    from json: String?,
    expectedText: String
  ) throws -> VoiceFormattedDocument? {
    guard let json else {
      return nil
    }
    do {
      let document = try JSONDecoder().decode(
        VoiceFormattedDocument.self,
        from: Data(json.utf8)
      )
      guard
        try VoiceFormattedTextRenderer().render(
          document,
          supportsMultiline: true
        ) == expectedText
      else {
        throw VoiceFormattingError.invalidBlock
      }
      return document
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid result formatting."
      )
    }
  }

  private func encodedHistoryFormattedDocument(
    _ result: VoiceHistoryResult
  ) throws -> String? {
    guard let document = result.formattedDocument else {
      return nil
    }
    do {
      guard
        try VoiceFormattedTextRenderer().render(
          document,
          supportsMultiline: true
        ) == result.text
      else {
        throw VoiceFormattingError.invalidBlock
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return String(decoding: try encoder.encode(document), as: UTF8.self)
    } catch {
      throw VoiceSessionHistoryError.invalidResult(
        "A Formatted History result contains invalid structured evidence."
      )
    }
  }

  private func timedSpans(
    from json: String?
  ) throws -> [VoiceHistoryTimedSpan] {
    guard let json else {
      return []
    }
    do {
      return try JSONDecoder().decode(
        [VoiceHistoryTimedSpan].self,
        from: Data(json.utf8)
      )
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid timed transcript spans."
      )
    }
  }

  private func encodedTimedSpans(
    _ spans: [VoiceHistoryTimedSpan]
  ) throws -> String? {
    guard !spans.isEmpty else {
      return nil
    }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return String(decoding: try encoder.encode(spans), as: UTF8.self)
    } catch {
      throw VoiceSessionHistoryError.invalidResult(
        "History could not store timed transcript spans."
      )
    }
  }

  private func deliveryFailureReason(
    from rawValue: String?
  ) throws -> VoiceSessionDeliveryFailureReason? {
    guard let rawValue else {
      return nil
    }
    guard
      let reason = VoiceSessionDeliveryFailureReason(
        rawValue: rawValue
      )
    else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains an invalid delivery failure reason."
      )
    }
    return reason
  }

  private func validateDeliveryEvidence(
    _ document: VoiceSessionDocument
  ) throws {
    guard document.deliveryFailureReason != nil else {
      return
    }
    guard
      document.deliveryOutcome == .failed,
      document.deliveryFailure != nil,
      document.deliveredText.isEmpty
    else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains contradictory delivery evidence."
      )
    }
  }

  private func formattedDocument(
    from json: String?,
    expectedRawText: String,
    expectedFormattedText: String
  ) throws -> VoiceFormattedDocument? {
    guard let json else {
      return nil
    }
    do {
      let document = try JSONDecoder().decode(
        VoiceFormattedDocument.self,
        from: Data(json.utf8)
      )
      guard document.rawText == expectedRawText else {
        throw VoiceFormattingError.invalidEvidenceReference
      }
      let rendered = try VoiceFormattedTextRenderer().render(
        document,
        supportsMultiline: true
      )
      guard rendered == expectedFormattedText else {
        throw VoiceFormattingError.invalidBlock
      }
      return document
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid structured formatting."
      )
    }
  }

  private func encodedFormattedDocument(
    _ document: VoiceFormattedDocument?,
    expectedRawText: String,
    expectedFormattedText: String
  ) throws -> String? {
    guard let document else {
      return nil
    }
    do {
      guard document.rawText == expectedRawText else {
        throw VoiceFormattingError.invalidEvidenceReference
      }
      let rendered = try VoiceFormattedTextRenderer().render(
        document,
        supportsMultiline: true
      )
      guard rendered == expectedFormattedText else {
        throw VoiceFormattingError.invalidBlock
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return String(decoding: try encoder.encode(document), as: UTF8.self)
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not store invalid structured formatting."
      )
    }
  }

  private func spokenEdits(
    from json: String?
  ) throws -> VoiceSpokenEditResult? {
    guard let json else {
      return nil
    }
    do {
      let result = try JSONDecoder().decode(
        VoiceSpokenEditResult.self,
        from: Data(json.utf8)
      )
      try VoiceSpokenEditReplayer().validate(result)
      return result
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid spoken-edit evidence."
      )
    }
  }

  private func encodedSpokenEdits(
    _ result: VoiceSpokenEditResult?
  ) throws -> String? {
    guard let result else {
      return nil
    }
    do {
      try VoiceSpokenEditReplayer().validate(result)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return String(decoding: try encoder.encode(result), as: UTF8.self)
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not store invalid spoken-edit evidence."
      )
    }
  }

  private static func addColumnIfNeeded(
    _ database: OpaquePointer,
    table: String = "voice_sessions",
    name expectedName: String,
    definition: String
  ) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "PRAGMA table_info(\(table));",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not inspect its local database."
      )
    }
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = sqlite3_column_text(statement, 1) else {
        continue
      }
      if String(cString: name) == expectedName {
        return
      }
    }
    try execute(
      database,
      sql: "ALTER TABLE \(table) ADD COLUMN \(expectedName) \(definition);"
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
