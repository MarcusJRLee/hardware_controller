import CryptoKit
import Foundation
import HardwareControllerVoiceCore
import SQLite3

private final class VoiceInputSQLiteHandle: @unchecked Sendable {
  let pointer: OpaquePointer
  private var isClosed = false

  init(pointer: OpaquePointer) {
    self.pointer = pointer
  }

  deinit {
    if !isClosed {
      sqlite3_close(pointer)
    }
  }

  func close() throws {
    guard !isClosed else {
      return
    }
    guard sqlite3_close(pointer) == SQLITE_OK else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    isClosed = true
  }
}

actor VoiceInputHistoryRepository {
  private static let schemaRevision = 1
  private static let transientDestructor = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
  )

  private let audioDirectoryURL: URL
  private let retentionSettings: VoiceHistoryRetentionSettings
  private let handle: VoiceInputSQLiteHandle
  private var isClosed = false

  private var database: OpaquePointer { handle.pointer }

  init(
    rootURL: URL,
    retentionSettings: VoiceHistoryRetentionSettings
  ) throws {
    audioDirectoryURL = rootURL.appendingPathComponent("audio", isDirectory: true)
    self.retentionSettings = try retentionSettings.validated()
    try Self.prepareOwnedDirectory(rootURL)
    try Self.prepareOwnedDirectory(audioDirectoryURL)

    var opened: OpaquePointer?
    let databaseURL = rootURL.appendingPathComponent("history.sqlite3")
    guard
      sqlite3_open_v2(
        databaseURL.path,
        &opened,
        SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
      ) == SQLITE_OK,
      let opened
    else {
      if let opened {
        sqlite3_close(opened)
      }
      throw VoiceInputHistoryError.storageUnavailable
    }
    handle = VoiceInputSQLiteHandle(pointer: opened)
    guard sqlite3_busy_timeout(opened, 5_000) == SQLITE_OK else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    try Self.execute(
      opened,
      sql: """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = FULL;
        CREATE TABLE IF NOT EXISTS voice_input_history (
          id TEXT PRIMARY KEY NOT NULL,
          schema_revision INTEGER NOT NULL,
          ended_at REAL NOT NULL,
          search_text TEXT NOT NULL,
          payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS voice_input_history_ended_at
        ON voice_input_history(ended_at DESC);
        """
    )
    try Self.removeIncompleteAudio(in: audioDirectoryURL)
    try Self.removeUnreferencedAudio(
      in: audioDirectoryURL,
      database: opened
    )
    try Self.protectDatabaseFiles(in: rootURL)
  }

  func save(
    sessionID: UUID,
    startedAt: Date,
    endedAt: Date,
    transcript: VoiceInputProcessedTranscript,
    sourceAudioURL: URL
  ) throws -> VoiceInputHistorySession {
    try requireOpen()
    guard
      startedAt <= endedAt,
      !transcript.rawTranscript.text.isEmpty,
      !transcript.editedText.isEmpty,
      !transcript.formattedText.isEmpty
    else {
      throw VoiceInputHistoryError.invalidSession
    }
    guard try session(id: sessionID) == nil else {
      throw VoiceInputHistoryError.duplicateSession
    }
    let artifact = try copyAudio(from: sourceAudioURL, sessionID: sessionID)
    let storedSession = VoiceInputHistorySession(
      id: sessionID,
      startedAt: startedAt,
      endedAt: endedAt,
      transcript: transcript,
      audioArtifact: artifact
    )
    do {
      try insert(storedSession)
    } catch {
      try? FileManager.default.removeItem(at: artifact.url)
      throw error
    }
    try applyRetention(now: endedAt)
    guard let stored = try session(id: sessionID) else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    return stored
  }

  func recent(limit: Int) throws -> [VoiceInputHistorySession] {
    try requireOpen()
    guard (1...1_000).contains(limit) else {
      throw VoiceInputHistoryError.invalidLimit
    }
    return try sessions(
      sql: """
        SELECT payload FROM voice_input_history
        ORDER BY ended_at DESC, id DESC
        LIMIT ?1;
        """,
      bind: { statement in
        guard sqlite3_bind_int(statement, 1, Int32(limit)) == SQLITE_OK else {
          throw VoiceInputHistoryError.storageUnavailable
        }
      }
    )
  }

  func search(
    query: String,
    limit: Int
  ) throws -> [VoiceInputHistorySession] {
    try requireOpen()
    guard (1...1_000).contains(limit) else {
      throw VoiceInputHistoryError.invalidLimit
    }
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return try recent(limit: limit)
    }
    let pattern = "%\(Self.escapedLikePattern(normalized))%"
    return try sessions(
      sql: """
        SELECT payload FROM voice_input_history
        WHERE search_text LIKE ?1 ESCAPE '\\' COLLATE NOCASE
        ORDER BY ended_at DESC, id DESC
        LIMIT ?2;
        """,
      bind: { statement in
        try Self.bind(pattern, at: 1, in: statement)
        guard sqlite3_bind_int(statement, 2, Int32(limit)) == SQLITE_OK else {
          throw VoiceInputHistoryError.storageUnavailable
        }
      }
    )
  }

  func session(id: UUID) throws -> VoiceInputHistorySession? {
    try requireOpen()
    return try sessions(
      sql: "SELECT payload FROM voice_input_history WHERE id = ?1 LIMIT 1;",
      bind: { statement in
        try Self.bind(id.uuidString, at: 1, in: statement)
      }
    ).first
  }

  func enforceRetention(now: Date) throws {
    try requireOpen()
    try applyRetention(now: now)
  }

  func close() throws {
    guard !isClosed else {
      return
    }
    try handle.close()
    isClosed = true
  }

  private func copyAudio(
    from sourceURL: URL,
    sessionID: UUID
  ) throws -> VoiceInputHistoryAudioArtifact {
    let filename = "\(sessionID.uuidString.lowercased()).caf"
    let destination = audioDirectoryURL.appendingPathComponent(filename)
    let staging = audioDirectoryURL.appendingPathComponent("\(filename).partial")
    guard
      !FileManager.default.fileExists(atPath: destination.path),
      !FileManager.default.fileExists(atPath: staging.path)
    else {
      throw VoiceInputHistoryError.duplicateSession
    }
    do {
      try FileManager.default.copyItem(at: sourceURL, to: staging)
      try Self.protectOwnedItem(staging)
      let file = try FileHandle(forWritingTo: staging)
      try file.synchronize()
      try file.close()
      try FileManager.default.moveItem(at: staging, to: destination)
      let attributes = try FileManager.default.attributesOfItem(
        atPath: destination.path
      )
      guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value else {
        throw VoiceInputHistoryError.storageUnavailable
      }
      return VoiceInputHistoryAudioArtifact(
        url: destination,
        byteCount: byteCount,
        sha256: try Self.sha256(of: destination)
      )
    } catch {
      try? FileManager.default.removeItem(at: staging)
      try? FileManager.default.removeItem(at: destination)
      if let error = error as? VoiceInputHistoryError {
        throw error
      }
      throw VoiceInputHistoryError.storageUnavailable
    }
  }

  private func insert(_ session: VoiceInputHistorySession) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        """
        INSERT INTO voice_input_history (
          id, schema_revision, ended_at, search_text, payload
        ) VALUES (?1, ?2, ?3, ?4, ?5);
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    defer { sqlite3_finalize(statement) }
    let payload = try Self.encode(session)
    try Self.bind(session.id.uuidString, at: 1, in: statement)
    guard
      sqlite3_bind_int(statement, 2, Int32(Self.schemaRevision)) == SQLITE_OK,
      sqlite3_bind_double(statement, 3, session.endedAt.timeIntervalSince1970) == SQLITE_OK
    else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    try Self.bind(Self.searchText(for: session), at: 4, in: statement)
    try Self.bind(payload, at: 5, in: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      if sqlite3_errcode(database) == SQLITE_CONSTRAINT {
        throw VoiceInputHistoryError.duplicateSession
      }
      throw VoiceInputHistoryError.storageUnavailable
    }
  }

  private func update(_ session: VoiceInputHistorySession) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        """
        UPDATE voice_input_history
        SET search_text = ?1, payload = ?2
        WHERE id = ?3;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    defer { sqlite3_finalize(statement) }
    try Self.bind(Self.searchText(for: session), at: 1, in: statement)
    try Self.bind(try Self.encode(session), at: 2, in: statement)
    try Self.bind(session.id.uuidString, at: 3, in: statement)
    guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
      throw VoiceInputHistoryError.storageUnavailable
    }
  }

  private func applyRetention(now: Date) throws {
    let retained = try allSessions().compactMap { session -> VoiceHistoryRetentionCandidate? in
      guard let artifact = session.audioArtifact else {
        return nil
      }
      return VoiceHistoryRetentionCandidate(
        id: session.id,
        endedAt: session.endedAt,
        audioBytes: artifact.byteCount,
        isPinned: false,
        isActive: false,
        isSoleRecoveryArtifact: false
      )
    }
    let plan = try VoiceHistoryRetentionPlanner.plan(
      candidates: retained,
      settings: retentionSettings,
      now: now
    )
    for decision in plan.decisions {
      guard
        let existing = try session(id: decision.sessionID),
        let artifact = existing.audioArtifact
      else {
        continue
      }
      try update(
        existing.expiringAudio(at: now, reason: decision.reason)
      )
      if FileManager.default.fileExists(atPath: artifact.url.path) {
        do {
          try FileManager.default.removeItem(at: artifact.url)
        } catch {
          throw VoiceInputHistoryError.storageUnavailable
        }
      }
    }
  }

  private func allSessions() throws -> [VoiceInputHistorySession] {
    try sessions(
      sql: """
        SELECT payload FROM voice_input_history
        ORDER BY ended_at DESC, id DESC;
        """,
      bind: { _ in }
    )
  }

  private func requireOpen() throws {
    guard !isClosed else {
      throw VoiceInputHistoryError.storageUnavailable
    }
  }

  private func sessions(
    sql: String,
    bind: (OpaquePointer) throws -> Void
  ) throws -> [VoiceInputHistorySession] {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    defer { sqlite3_finalize(statement) }
    try bind(statement)
    var sessions: [VoiceInputHistorySession] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard
          let bytes = sqlite3_column_blob(statement, 0),
          sqlite3_column_bytes(statement, 0) > 0
        else {
          throw VoiceInputHistoryError.invalidSession
        }
        let payload = Data(
          bytes: bytes,
          count: Int(sqlite3_column_bytes(statement, 0))
        )
        let session: VoiceInputHistorySession
        do {
          session = try Self.decode(payload)
        } catch {
          throw VoiceInputHistoryError.invalidSession
        }
        sessions.append(
          try session.validated(audioDirectoryURL: audioDirectoryURL)
        )
      case SQLITE_DONE:
        return sessions
      default:
        throw VoiceInputHistoryError.storageUnavailable
      }
    }
  }

  private static func prepareOwnedDirectory(_ url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [
          .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
      )
      try protectOwnedItem(url)
    } catch {
      throw VoiceInputHistoryError.storageUnavailable
    }
  }

  private static func protectOwnedItem(_ url: URL) throws {
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: url.path
    )
    var ownedURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try ownedURL.setResourceValues(values)
  }

  private static func removeIncompleteAudio(in directory: URL) throws {
    let children = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    for child in children where child.lastPathComponent.hasSuffix(".partial") {
      try FileManager.default.removeItem(at: child)
    }
  }

  private static func removeUnreferencedAudio(
    in directory: URL,
    database: OpaquePointer
  ) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT payload FROM voice_input_history;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK,
      let statement
    else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    defer { sqlite3_finalize(statement) }
    var referencedFilenames: Set<String> = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        guard
          let bytes = sqlite3_column_blob(statement, 0),
          sqlite3_column_bytes(statement, 0) > 0,
          let session = try? decode(
            Data(
              bytes: bytes,
              count: Int(sqlite3_column_bytes(statement, 0))
            )
          ),
          session.schemaRevision == schemaRevision,
          (try? session.validated(audioDirectoryURL: directory)) != nil
        else {
          throw VoiceInputHistoryError.invalidSession
        }
        if session.audioArtifact != nil {
          referencedFilenames.insert(
            "\(session.id.uuidString.lowercased()).caf"
          )
        }
      case SQLITE_DONE:
        let children = try FileManager.default.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: nil
        )
        for child in children
        where child.pathExtension == "caf"
          && !referencedFilenames.contains(child.lastPathComponent)
        {
          try FileManager.default.removeItem(at: child)
        }
        return
      default:
        throw VoiceInputHistoryError.storageUnavailable
      }
    }
  }

  private static func protectDatabaseFiles(in root: URL) throws {
    for filename in ["history.sqlite3", "history.sqlite3-wal", "history.sqlite3-shm"] {
      let url = root.appendingPathComponent(filename)
      if FileManager.default.fileExists(atPath: url.path) {
        try protectOwnedItem(url)
      }
    }
  }

  private static func sha256(of url: URL) throws -> String {
    do {
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      var hasher = SHA256()
      while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
        hasher.update(data: data)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    } catch {
      throw VoiceInputHistoryError.storageUnavailable
    }
  }

  private static func execute(_ database: OpaquePointer, sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw VoiceInputHistoryError.storageUnavailable
    }
  }

  private static func bind(
    _ value: String,
    at index: Int32,
    in statement: OpaquePointer
  ) throws {
    guard
      value.withCString({
        sqlite3_bind_text(statement, index, $0, -1, transientDestructor)
      }) == SQLITE_OK
    else {
      throw VoiceInputHistoryError.storageUnavailable
    }
  }

  private static func bind(
    _ value: Data,
    at index: Int32,
    in statement: OpaquePointer
  ) throws {
    let result = value.withUnsafeBytes { bytes in
      sqlite3_bind_blob(
        statement,
        index,
        bytes.baseAddress,
        Int32(bytes.count),
        transientDestructor
      )
    }
    guard result == SQLITE_OK else {
      throw VoiceInputHistoryError.storageUnavailable
    }
  }

  private static func escapedLikePattern(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  private static func searchText(for session: VoiceInputHistorySession) -> String {
    [session.rawText, session.editedText, session.formattedText]
      .joined(separator: "\n")
  }

  private static func encode(_ session: VoiceInputHistorySession) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(session)
  }

  private static func decode(_ payload: Data) throws -> VoiceInputHistorySession {
    try JSONDecoder().decode(VoiceInputHistorySession.self, from: payload)
  }
}
