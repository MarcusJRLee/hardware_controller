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
  static let lowDiskReserveBytes: Int64 = 1_024 * 1_024 * 1_024

  private static let schemaRevision = VoiceInputHistorySession.currentSchemaRevision
  private static let transientDestructor = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
  )

  private let audioDirectoryURL: URL
  private var retentionSettings: VoiceHistoryRetentionSettings
  private let availableCapacity: @Sendable (URL) throws -> Int64?
  private let removeRetainedAudio: @Sendable (URL) throws -> Void
  private let handle: VoiceInputSQLiteHandle
  private var isClosed = false
  private var needsReconciliation = true
  private var maintenanceMessage: String?

  private var database: OpaquePointer { handle.pointer }

  init(
    rootURL: URL,
    retentionSettings: VoiceHistoryRetentionSettings,
    availableCapacity: @escaping @Sendable (URL) throws -> Int64? = {
      url in
      try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        .volumeAvailableCapacity.map(Int64.init)
    },
    removeRetainedAudio: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.removeItem(at: $0)
    }
  ) throws {
    audioDirectoryURL = rootURL.appendingPathComponent("audio", isDirectory: true)
    self.retentionSettings = try retentionSettings.validated()
    self.availableCapacity = availableCapacity
    self.removeRetainedAudio = removeRetainedAudio
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
    try Self.protectDatabaseFiles(in: rootURL)
  }

  func save(
    sessionID: UUID,
    startedAt: Date,
    endedAt: Date,
    transcript: VoiceInputProcessedTranscript,
    sourceAudioURL: URL
  ) throws -> VoiceInputHistorySession {
    try reconcileIfNeeded(excluding: sourceAudioURL)
    try requireOpen()
    guard
      startedAt <= endedAt,
      !transcript.rawTranscript.text.isEmpty,
      !transcript.editedText.isEmpty,
      !transcript.formattedText.isEmpty
    else {
      throw VoiceInputHistoryError.invalidSession
    }
    guard try storedSession(id: sessionID) == nil else {
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
    enforceAfterCommit(now: endedAt)
    guard let stored = try session(id: sessionID) else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    return stored
  }

  func saveRecovery(
    sessionID: UUID,
    startedAt: Date,
    endedAt: Date,
    reason: VoiceInputCaptureInterruptionReason,
    sourceAudioURL: URL
  ) throws -> VoiceInputHistorySession {
    try reconcileIfNeeded(excluding: sourceAudioURL)
    try requireOpen()
    guard startedAt <= endedAt else {
      throw VoiceInputHistoryError.invalidSession
    }
    if let existing = try storedSession(id: sessionID) {
      let expectedPartialURL = audioDirectoryURL.appendingPathComponent(
        "\(sessionID.uuidString.lowercased()).partial"
      )
      guard
        let existingArtifact = existing.audioArtifact,
        sourceAudioURL.standardizedFileURL == expectedPartialURL.standardizedFileURL,
        let sourceDigest = try? Self.sha256(of: sourceAudioURL),
        sourceDigest == existingArtifact.sha256
      else {
        throw VoiceInputHistoryError.duplicateSession
      }
      if FileManager.default.fileExists(atPath: sourceAudioURL.path) {
        try FileManager.default.removeItem(at: sourceAudioURL)
      }
      return existing
    }
    let artifact = try copyAudio(from: sourceAudioURL, sessionID: sessionID)
    let recovered = VoiceInputHistorySession(
      recoveryID: sessionID,
      startedAt: startedAt,
      endedAt: endedAt,
      reason: reason,
      audioArtifact: artifact
    )
    do {
      try insert(recovered)
      if sourceAudioURL.standardizedFileURL != artifact.url.standardizedFileURL {
        try FileManager.default.removeItem(at: sourceAudioURL)
      }
    } catch {
      try? FileManager.default.removeItem(at: artifact.url)
      throw error
    }
    enforceAfterCommit(now: endedAt)
    guard let stored = try session(id: sessionID) else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    return stored
  }

  func recent(limit: Int) throws -> [VoiceInputHistorySession] {
    try reconcileIfNeeded()
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
    try reconcileIfNeeded()
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
    try reconcileIfNeeded()
    try requireOpen()
    return try storedSession(id: id)
  }

  private func storedSession(id: UUID) throws -> VoiceInputHistorySession? {
    return try sessions(
      sql: "SELECT payload FROM voice_input_history WHERE id = ?1 LIMIT 1;",
      bind: { statement in
        try Self.bind(id.uuidString, at: 1, in: statement)
      }
    ).first
  }

  @discardableResult
  func enforceRetention(now: Date) throws -> VoiceHistoryRetentionPlan {
    try reconcileIfNeeded()
    try requireOpen()
    do {
      return try applyRetention(now: now)
    } catch {
      maintenanceMessage = "History storage maintenance could not finish and will retry."
      throw error
    }
  }

  func setRetentionSettings(
    _ settings: VoiceHistoryRetentionSettings,
    now: Date
  ) throws -> VoiceHistoryRetentionPlan {
    retentionSettings = try settings.validated()
    return try enforceRetention(now: now)
  }

  func setPinned(
    sessionID: UUID,
    isPinned: Bool
  ) throws -> VoiceInputHistorySession {
    try reconcileIfNeeded()
    try requireOpen()
    guard let existing = try storedSession(id: sessionID), existing.audioArtifact != nil else {
      throw VoiceInputHistoryError.invalidSession
    }
    let updated = existing.settingPinned(isPinned)
    try update(updated)
    return updated
  }

  func retentionMaintenanceMessage() -> String? {
    maintenanceMessage
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
        SET schema_revision = ?1, search_text = ?2, payload = ?3
        WHERE id = ?4;
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
    guard
      sqlite3_bind_int(statement, 1, Int32(Self.schemaRevision)) == SQLITE_OK
    else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    try Self.bind(Self.searchText(for: session), at: 2, in: statement)
    try Self.bind(try Self.encode(session), at: 3, in: statement)
    try Self.bind(session.id.uuidString, at: 4, in: statement)
    guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
      throw VoiceInputHistoryError.storageUnavailable
    }
  }

  private func applyRetention(now: Date) throws -> VoiceHistoryRetentionPlan {
    let retained = try allSessions().compactMap { session -> VoiceHistoryRetentionCandidate? in
      guard let artifact = session.audioArtifact else {
        return nil
      }
      return VoiceHistoryRetentionCandidate(
        id: session.id,
        endedAt: session.endedAt,
        audioBytes: artifact.byteCount,
        isPinned: session.isPinned,
        isActive: false,
        isSoleRecoveryArtifact: session.recoveryReason != nil,
        recoveryExpiresAt: session.recoveryExpiresAt
      )
    }
    let lowDiskReclaimBytes = try automaticLowDiskReclaimBytes()
    let plan = try VoiceHistoryRetentionPlanner.plan(
      candidates: retained,
      settings: retentionSettings,
      now: now,
      lowDiskReclaimBytes: lowDiskReclaimBytes
    )
    for decision in plan.decisions {
      guard
        let existing = try session(id: decision.sessionID),
        let artifact = existing.audioArtifact
      else {
        continue
      }
      try update(existing.expiringAudio(at: now, reason: decision.reason))
      if FileManager.default.fileExists(atPath: artifact.url.path) {
        do {
          try removeRetainedAudio(artifact.url)
        } catch {
          // Restore the evidence reference so a failed deletion remains retryable.
          try update(existing)
          throw VoiceInputHistoryError.storageUnavailable
        }
      }
    }
    maintenanceMessage = Self.maintenanceMessage(for: plan)
    return plan
  }

  private func enforceAfterCommit(now: Date) {
    do {
      _ = try applyRetention(now: now)
    } catch {
      maintenanceMessage = "History storage maintenance could not finish and will retry."
    }
  }

  private func automaticLowDiskReclaimBytes() throws -> Int64 {
    guard let capacity = try availableCapacity(audioDirectoryURL) else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    guard capacity >= 0 else {
      throw VoiceHistoryRetentionValidationError.invalidReclaimRequest
    }
    return max(0, Self.lowDiskReserveBytes - capacity)
  }

  private static func maintenanceMessage(
    for plan: VoiceHistoryRetentionPlan
  ) -> String? {
    if plan.lowDiskShortfallBytes > 0 {
      return "Pinned or recovery audio blocks the 1 GiB free-space reserve."
    }
    if plan.exceedsByteLimit || plan.exceedsArtifactLimit {
      return "Pinned or recovery audio currently exceeds a History storage limit."
    }
    return nil
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

  private func reconcileIfNeeded(excluding excludedURL: URL? = nil) throws {
    guard needsReconciliation else {
      return
    }
    do {
      try reconcileInterruptedAudio(excluding: excludedURL)
      needsReconciliation = false
    } catch {
      needsReconciliation = true
      throw error
    }
  }

  private func reconcileInterruptedAudio(excluding excludedURL: URL?) throws {
    let children = try FileManager.default.contentsOfDirectory(
      at: audioDirectoryURL,
      includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
    )
    let finalized = children.compactMap { url -> (UUID, URL)? in
      guard
        url.standardizedFileURL != excludedURL?.standardizedFileURL,
        url.pathExtension == "caf",
        let id = Self.canonicalSessionID(
          filename: url.deletingPathExtension().lastPathComponent
        )
      else {
        return nil
      }
      return (id, url)
    }.sorted { $0.1.lastPathComponent < $1.1.lastPathComponent }
    for (requestedID, artifactURL) in finalized {
      guard Self.isRecoverableAudioArtifact(artifactURL) else {
        continue
      }
      if let existing = try storedSession(id: requestedID) {
        if existing.audioArtifact == nil {
          try FileManager.default.removeItem(at: artifactURL)
        }
      } else {
        try adoptRecoveryAudio(at: artifactURL, requestedID: requestedID)
      }
    }

    let partials = children.compactMap { url -> (UUID, URL)? in
      guard
        url.standardizedFileURL != excludedURL?.standardizedFileURL,
        url.pathExtension == "partial",
        url.deletingPathExtension().pathExtension.isEmpty,
        let id = Self.canonicalSessionID(
          filename: url.deletingPathExtension().lastPathComponent
        )
      else {
        return nil
      }
      return (id, url)
    }.sorted { $0.1.lastPathComponent < $1.1.lastPathComponent }
    for (requestedID, partialURL) in partials {
      guard Self.isRecoverableAudioArtifact(partialURL) else {
        continue
      }
      let existing = try storedSession(id: requestedID)
      if let existingArtifact = existing?.audioArtifact,
        existingArtifact.sha256 == (try Self.sha256(of: partialURL))
      {
        try FileManager.default.removeItem(at: partialURL)
        continue
      }
      let recoveryID = existing == nil ? requestedID : UUID()
      try recoverPartialAudio(at: partialURL, recoveryID: recoveryID)
    }
  }

  /// Invalid artifacts remain untouched so one damaged recording cannot hide valid History.
  private static func isRecoverableAudioArtifact(_ url: URL) -> Bool {
    guard
      let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .fileSizeKey]
      ),
      values.isRegularFile == true,
      let fileSize = values.fileSize,
      fileSize > 0,
      (try? artifactTimestamps(url)) != nil,
      (try? sha256(of: url)) != nil
    else {
      return false
    }
    return true
  }

  private func recoverPartialAudio(
    at sourceURL: URL,
    recoveryID: UUID
  ) throws {
    let timestamps = try Self.artifactTimestamps(sourceURL)
    let artifact = try copyAudio(from: sourceURL, sessionID: recoveryID)
    let recovered = VoiceInputHistorySession(
      recoveryID: recoveryID,
      startedAt: timestamps.startedAt,
      endedAt: timestamps.endedAt,
      reason: .processTermination,
      audioArtifact: artifact
    )
    do {
      try insert(recovered)
      try FileManager.default.removeItem(at: sourceURL)
    } catch {
      try? FileManager.default.removeItem(at: artifact.url)
      throw error
    }
  }

  private func adoptRecoveryAudio(
    at artifactURL: URL,
    requestedID: UUID
  ) throws {
    let timestamps = try Self.artifactTimestamps(artifactURL)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: artifactURL.path
    )
    guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value,
      byteCount > 0
    else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    try Self.protectOwnedItem(artifactURL)
    try insert(
      VoiceInputHistorySession(
        recoveryID: requestedID,
        startedAt: timestamps.startedAt,
        endedAt: timestamps.endedAt,
        reason: .processTermination,
        audioArtifact: VoiceInputHistoryAudioArtifact(
          url: artifactURL,
          byteCount: byteCount,
          sha256: try Self.sha256(of: artifactURL)
        )
      )
    )
  }

  private static func artifactTimestamps(
    _ url: URL
  ) throws -> (startedAt: Date, endedAt: Date) {
    let values = try url.resourceValues(
      forKeys: [.creationDateKey, .contentModificationDateKey]
    )
    guard let startedAt = values.creationDate ?? values.contentModificationDate,
      let endedAt = values.contentModificationDate ?? values.creationDate
    else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    return (
      startedAt: min(startedAt, endedAt),
      endedAt: max(startedAt, endedAt)
    )
  }

  private static func canonicalSessionID(filename: String) -> UUID? {
    guard
      filename == filename.lowercased(),
      let id = UUID(uuidString: filename),
      id.uuidString.lowercased() == filename
    else {
      return nil
    }
    return id
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
