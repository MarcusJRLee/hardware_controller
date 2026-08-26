import Foundation
import HardwareControllerCore
import SQLite3

private final class SQLiteVoiceHistoryRetentionDatabaseHandle:
  @unchecked Sendable
{
  let pointer: OpaquePointer

  init(_ pointer: OpaquePointer) {
    self.pointer = pointer
  }

  deinit {
    sqlite3_close(pointer)
  }
}

/// Owns automatic Voice audio selection, expiration evidence, and file removal.
actor SQLiteVoiceHistoryRetentionStore {
  static let lowDiskReserveBytes: Int64 = 1_024 * 1_024 * 1_024

  private struct RetainedAudioDescriptor {
    let sessionID: UUID
    let endedAt: Date
    let deliveryOutcome: VoiceSessionDeliveryOutcome
    let filename: String
    let isPinned: Bool
    let recoveryKind: VoiceHistoryRecoveryKind?
    let recoveredAt: Date?
  }

  /// SQLite uses the -1 sentinel to copy bound text before Swift releases it.
  private static let transientDestructor = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
  )

  private let handle: SQLiteVoiceHistoryRetentionDatabaseHandle
  private let audioDirectory: URL
  private let artifactSize: @Sendable (URL) throws -> Int64
  private let availableCapacity: @Sendable (URL) throws -> Int64?

  private var database: OpaquePointer { handle.pointer }

  init(
    databaseURL: URL,
    audioDirectory: URL,
    artifactSize: @escaping @Sendable (URL) throws -> Int64 = {
      url in
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      guard let size = values.fileSize else {
        throw CocoaError(.fileReadUnknown)
      }
      return Int64(size)
    },
    availableCapacity: @escaping @Sendable (URL) throws -> Int64? = {
      url in
      try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        .volumeAvailableCapacity.map(Int64.init)
    }
  ) throws {
    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      databaseURL.path,
      &opened,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard result == SQLITE_OK, let opened else {
      if let opened {
        sqlite3_close(opened)
      }
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not open retention storage."
      )
    }
    handle = SQLiteVoiceHistoryRetentionDatabaseHandle(opened)
    self.audioDirectory = audioDirectory
    self.artifactSize = artifactSize
    self.availableCapacity = availableCapacity
    guard sqlite3_busy_timeout(opened, 2_000) == SQLITE_OK else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not coordinate retention storage."
      )
    }
  }

  func enforce(
    settings: VoiceHistoryRetentionSettings,
    now: Date,
    activeSessionIDs: Set<UUID>,
    lowDiskReclaimBytes: Int64
  ) throws -> VoiceHistoryRetentionReport {
    guard lowDiskReclaimBytes >= 0 else {
      throw VoiceHistoryRetentionValidationError.invalidReclaimRequest
    }
    let descriptorQuery = try retainedAudioDescriptors()
    let descriptors = descriptorQuery.descriptors
    var candidates: [VoiceHistoryRetentionCandidate] = []
    var issues: [VoiceHistoryRetentionIssue] = []
    if descriptorQuery.invalidRecordCount > 0 {
      issues.append(
        .maintenanceUnavailable(
          "Voice History isolated invalid retention metadata."
        )
      )
    }
    for descriptor in descriptors {
      let url = audioDirectory.appending(path: descriptor.filename)
      guard FileManager.default.fileExists(atPath: url.path) else {
        issues.append(.missingArtifact(sessionID: descriptor.sessionID))
        continue
      }
      do {
        let size = try artifactSize(url)
        guard size >= 0 else {
          issues.append(
            .unreadableArtifactSize(sessionID: descriptor.sessionID)
          )
          continue
        }
        candidates.append(
          VoiceHistoryRetentionCandidate(
            id: descriptor.sessionID,
            endedAt: descriptor.endedAt,
            audioBytes: size,
            isPinned: descriptor.isPinned,
            isActive: activeSessionIDs.contains(descriptor.sessionID),
            isSoleRecoveryArtifact:
              descriptor.deliveryOutcome != .inserted
              || descriptor.recoveryKind != nil,
            recoveryExpiresAt: descriptor.recoveredAt.map {
              $0.addingTimeInterval(86_400)
            }
          )
        )
      } catch {
        issues.append(
          .unreadableArtifactSize(sessionID: descriptor.sessionID)
        )
      }
    }

    let measuredLowDiskReclaimBytes: Int64
    do {
      measuredLowDiskReclaimBytes = try automaticLowDiskReclaimBytes()
    } catch {
      measuredLowDiskReclaimBytes = 0
      issues.append(
        .maintenanceUnavailable(
          "Voice History could not inspect available disk capacity."
        )
      )
    }
    let effectiveLowDiskReclaimBytes = max(
      lowDiskReclaimBytes,
      measuredLowDiskReclaimBytes
    )
    let plan = try VoiceHistoryRetentionPlanner.plan(
      candidates: candidates,
      settings: settings,
      now: now,
      lowDiskReclaimBytes: effectiveLowDiskReclaimBytes
    )
    var expired: [VoiceHistoryRetentionDecision] = []
    var actuallyReclaimedBytes: Int64 = 0
    let endedAtBySessionID = Dictionary(
      uniqueKeysWithValues: candidates.map { ($0.id, $0.endedAt) }
    )
    for decision in plan.decisions {
      do {
        let endedAt = endedAtBySessionID[decision.sessionID] ?? now
        let removed = try expireAudio(
          decision,
          at: max(now, endedAt.addingTimeInterval(0.001))
        )
        expired.append(decision)
        if removed {
          actuallyReclaimedBytes += decision.audioBytes
        } else {
          issues.append(.removalFailed(sessionID: decision.sessionID))
        }
      } catch {
        issues.append(.removalFailed(sessionID: decision.sessionID))
      }
    }
    let actualLowDiskShortfallBytes = max(
      plan.lowDiskShortfallBytes,
      effectiveLowDiskReclaimBytes - actuallyReclaimedBytes
    )
    if actualLowDiskShortfallBytes > 0 {
      issues.append(.lowDiskShortfall(bytes: actualLowDiskShortfallBytes))
    }
    if plan.exceedsByteLimit, let maximum = settings.maximumAudioBytes {
      issues.append(
        .byteLimitUnmet(bytes: max(0, plan.remainingAudioBytes - maximum))
      )
    }
    if plan.exceedsArtifactLimit,
      let maximum = settings.maximumArtifactCount
    {
      issues.append(
        .artifactLimitUnmet(
          count: max(0, plan.remainingArtifactCount - maximum)
        )
      )
    }
    return VoiceHistoryRetentionReport(
      completedAt: now,
      expired: expired,
      issues: issues
    )
  }

  private func automaticLowDiskReclaimBytes() throws -> Int64 {
    guard let capacity = try availableCapacity(audioDirectory) else {
      return 0
    }
    guard capacity >= 0 else {
      throw VoiceHistoryRetentionValidationError.invalidReclaimRequest
    }
    return max(0, Self.lowDiskReserveBytes - capacity)
  }

  private func retainedAudioDescriptors() throws
    -> (
      descriptors: [RetainedAudioDescriptor],
      invalidRecordCount: Int
    )
  {
    let sql = """
      SELECT id, ended_at, delivery_outcome, audio_filename, is_pinned,
        recovery_kind, recovered_at
      FROM voice_sessions
      WHERE audio_filename IS NOT NULL
      ORDER BY ended_at ASC, id ASC;
      """
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw storageFailure()
    }
    defer { sqlite3_finalize(statement) }
    var descriptors: [RetainedAudioDescriptor] = []
    var invalidRecordCount = 0
    while true {
      let result = sqlite3_step(statement)
      guard result != SQLITE_DONE else {
        return (descriptors, invalidRecordCount)
      }
      guard result == SQLITE_ROW else {
        throw storageFailure()
      }
      let endedAtRaw = sqlite3_column_double(statement, 1)
      let endedAt = Date(timeIntervalSince1970: endedAtRaw)
      let filename = text(statement, column: 3)
      let pinned = sqlite3_column_int(statement, 4)
      let recoveryKindRaw = optionalText(statement, column: 5)
      let recoveredAtRaw = optionalDouble(statement, column: 6)
      let recoveryKind = recoveryKindRaw.flatMap(
        VoiceHistoryRecoveryKind.init(rawValue:)
      )
      guard
        let sessionID = UUID(uuidString: text(statement, column: 0)),
        let deliveryOutcome = VoiceSessionDeliveryOutcome(
          rawValue: text(statement, column: 2)
        ),
        endedAtRaw.isFinite,
        filename == "\(sessionID.uuidString).caf",
        recoveredAtRaw.map({ $0.isFinite && $0 >= endedAtRaw }) ?? true,
        pinned == 0 || pinned == 1,
        recoveryKindRaw == nil || recoveryKind != nil,
        (recoveryKind == nil) == (recoveredAtRaw == nil)
      else {
        invalidRecordCount += 1
        continue
      }
      descriptors.append(
        RetainedAudioDescriptor(
          sessionID: sessionID,
          endedAt: endedAt,
          deliveryOutcome: deliveryOutcome,
          filename: filename,
          isPinned: pinned == 1,
          recoveryKind: recoveryKind,
          recoveredAt: recoveredAtRaw.map(Date.init(timeIntervalSince1970:))
        )
      )
    }
  }

  /// Returns false only when committed expiration left a quarantined artifact.
  private func expireAudio(
    _ decision: VoiceHistoryRetentionDecision,
    at expiredAt: Date
  ) throws -> Bool {
    let filename = "\(decision.sessionID.uuidString).caf"
    let originalURL = audioDirectory.appending(path: filename)
    let quarantineURL = audioDirectory.appending(
      path: ".expiring_\(decision.sessionID.uuidString)_\(UUID().uuidString).caf"
    )
    do {
      try FileManager.default.moveItem(
        at: originalURL,
        to: quarantineURL
      )
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not prepare retained audio for expiration."
      )
    }

    do {
      try execute("BEGIN IMMEDIATE;")
      try markAudioExpired(
        decision,
        filename: filename,
        at: expiredAt
      )
      try execute("COMMIT;")
    } catch {
      var recoveryFailed = false
      do {
        try execute("ROLLBACK;")
      } catch {
        recoveryFailed = true
      }
      if FileManager.default.fileExists(atPath: quarantineURL.path) {
        do {
          try FileManager.default.moveItem(
            at: quarantineURL,
            to: originalURL
          )
        } catch {
          recoveryFailed = true
        }
      }
      if recoveryFailed {
        throw VoiceSessionHistoryError.storageUnavailable(
          "Voice History could not recover an interrupted audio expiration."
        )
      }
      throw error
    }

    do {
      try FileManager.default.removeItem(at: quarantineURL)
      return true
    } catch {
      return false
    }
  }

  private func markAudioExpired(
    _ decision: VoiceHistoryRetentionDecision,
    filename: String,
    at expiredAt: Date
  ) throws {
    let sql = """
      UPDATE voice_sessions
      SET audio_filename = NULL,
        audio_expired_at = ?, audio_expiration_reason = ?
      WHERE id = ? AND audio_filename = ?
        AND is_pinned = 0
        AND (delivery_outcome = 'inserted' OR recovery_kind IS NOT NULL);
      """
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw storageFailure()
    }
    defer { sqlite3_finalize(statement) }
    guard
      sqlite3_bind_double(
        statement,
        1,
        expiredAt.timeIntervalSince1970
      ) == SQLITE_OK
    else {
      throw storageFailure()
    }
    try bind(decision.reason.rawValue, to: 2, in: statement)
    try bind(decision.sessionID.uuidString, to: 3, in: statement)
    try bind(filename, to: 4, in: statement)
    guard sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(database) == 1
    else {
      throw storageFailure()
    }
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw storageFailure()
    }
  }

  private func bind(
    _ value: String,
    to index: Int32,
    in statement: OpaquePointer
  ) throws {
    guard
      sqlite3_bind_text(
        statement,
        index,
        value,
        -1,
        Self.transientDestructor
      ) == SQLITE_OK
    else {
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

  private func optionalDouble(
    _ statement: OpaquePointer,
    column: Int32
  ) -> Double? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
      return nil
    }
    return sqlite3_column_double(statement, column)
  }

  private func storageFailure() -> VoiceSessionHistoryError {
    .storageUnavailable(
      "Voice History could not update retention metadata."
    )
  }
}
