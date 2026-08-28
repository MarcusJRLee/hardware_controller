import Foundation
import HardwareControllerVoiceCore
import SQLite3
import XCTest

@testable import VoiceInput

final class VoiceInputHistoryRepositoryTest: XCTestCase {
  func testCompletedSessionSurvivesReloadAndSearchWithImmutableStages() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try await fixture.remove() }
    let processed = try fixture.process(
      "Keep this. Remove this scratch that Ship Monday."
    )

    let saved = try await fixture.repository.save(
      sessionID: UUID(),
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: processed,
      sourceAudioURL: fixture.audioURL
    )
    let reloaded = try VoiceInputHistoryRepository(
      rootURL: fixture.historyRoot,
      retentionSettings: .iOSDefault
    )
    addTeardownBlock { try await reloaded.close() }

    let matches = try await reloaded.search(query: "Ship Monday", limit: 20)

    XCTAssertEqual(matches, [saved])
    XCTAssertEqual(saved.rawText, "Keep this. Remove this scratch that Ship Monday.")
    XCTAssertEqual(saved.editedText, "Keep this. Ship Monday.")
    XCTAssertEqual(saved.formattedText, "Keep this. Ship Monday.")
    XCTAssertEqual(saved.spokenEdits.operations.map(\.kind), [.deleteCurrentClause])
    XCTAssertEqual(saved.timedSegments.count, 1)
    let artifact = try XCTUnwrap(saved.audioArtifact)
    XCTAssertEqual(artifact.byteCount, 7)
    XCTAssertEqual(artifact.sha256.count, 64)
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
  }

  func testConfiguredArtifactCapExpiresOldAudioWithoutDeletingTranscript() async throws {
    let fixture = try Fixture(
      retentionSettings: VoiceHistoryRetentionSettings(
        maximumAgeDays: nil,
        maximumAudioBytes: nil,
        maximumArtifactCount: 1
      )
    )
    addTeardownBlock { try await fixture.remove() }
    let firstID = UUID()
    _ = try await fixture.repository.save(
      sessionID: firstID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("First retained transcript."),
      sourceAudioURL: fixture.audioURL
    )
    _ = try await fixture.repository.save(
      sessionID: UUID(),
      startedAt: Date(timeIntervalSince1970: 30),
      endedAt: Date(timeIntervalSince1970: 40),
      transcript: try fixture.process("Second retained transcript."),
      sourceAudioURL: fixture.audioURL
    )

    let sessions = try await fixture.repository.recent(limit: 20)
    let first = try XCTUnwrap(sessions.first { $0.id == firstID })

    XCTAssertEqual(sessions.count, 2)
    XCTAssertEqual(first.formattedText, "First retained transcript.")
    XCTAssertNil(first.audioArtifact)
    XCTAssertEqual(first.audioExpiredReason, .artifactLimit)
    XCTAssertNotNil(first.audioExpiredAt)
  }

  func testPinnedAudioIsSkippedWhenTheArtifactCapIsEnforced() async throws {
    let fixture = try Fixture(
      retentionSettings: VoiceHistoryRetentionSettings(
        maximumAgeDays: nil,
        maximumAudioBytes: nil,
        maximumArtifactCount: 1
      )
    )
    addTeardownBlock { try await fixture.remove() }
    let pinnedID = UUID()
    _ = try await fixture.repository.save(
      sessionID: pinnedID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Keep pinned audio."),
      sourceAudioURL: fixture.audioURL
    )
    _ = try await fixture.repository.setPinned(
      sessionID: pinnedID,
      isPinned: true
    )
    let unpinnedID = UUID()
    _ = try await fixture.repository.save(
      sessionID: unpinnedID,
      startedAt: Date(timeIntervalSince1970: 30),
      endedAt: Date(timeIntervalSince1970: 40),
      transcript: try fixture.process("Expire unpinned audio."),
      sourceAudioURL: fixture.audioURL
    )

    let pinned = try await fixture.repository.session(id: pinnedID)
    let unpinned = try await fixture.repository.session(id: unpinnedID)

    XCTAssertEqual(pinned?.isPinned, true)
    XCTAssertNotNil(pinned?.audioArtifact)
    XCTAssertNil(unpinned?.audioArtifact)
    XCTAssertEqual(unpinned?.audioExpiredReason, .artifactLimit)
  }

  func testPinnedRecoveryAudioSurvivesItsAutomaticExpiry() async throws {
    let fixture = try Fixture(retentionSettings: .unlimited)
    addTeardownBlock { try await fixture.remove() }
    let sessionID = UUID()
    let endedAt = Date(timeIntervalSince1970: 20)
    _ = try await fixture.repository.saveRecovery(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: endedAt,
      reason: .audioInterruption,
      sourceAudioURL: fixture.audioURL
    )
    _ = try await fixture.repository.setPinned(
      sessionID: sessionID,
      isPinned: true
    )

    _ = try await fixture.repository.enforceRetention(
      now: endedAt.addingTimeInterval(86_400)
    )
    let recovered = try await fixture.repository.session(id: sessionID)

    XCTAssertEqual(recovered?.isPinned, true)
    XCTAssertNotNil(recovered?.audioArtifact)
    XCTAssertNil(recovered?.audioExpiredReason)
  }

  func testPinUpdateAdvancesTheStoredSchemaRevision() async throws {
    let fixture = try Fixture(retentionSettings: .unlimited)
    addTeardownBlock { try await fixture.remove() }
    let saved = try await fixture.repository.save(
      sessionID: UUID(),
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Persist pin schema."),
      sourceAudioURL: fixture.audioURL
    )
    try await fixture.repository.close()
    let databaseURL = fixture.historyRoot.appendingPathComponent("history.sqlite3")
    try setStoredSchemaRevision(2, databaseURL: databaseURL)
    let reloaded = try VoiceInputHistoryRepository(
      rootURL: fixture.historyRoot,
      retentionSettings: .unlimited,
      availableCapacity: { _ in VoiceInputHistoryRepository.lowDiskReserveBytes }
    )
    addTeardownBlock { try await reloaded.close() }

    _ = try await reloaded.setPinned(sessionID: saved.id, isPinned: true)
    try await reloaded.close()

    XCTAssertEqual(
      try storedSchemaRevision(databaseURL: databaseURL),
      VoiceInputHistorySession.currentSchemaRevision
    )
  }

  func testLowDiskReserveExpiresEligibleAudioWithoutDeletingTranscript() async throws {
    let fixture = try Fixture(
      retentionSettings: .unlimited,
      availableCapacity: { _ in
        VoiceInputHistoryRepository.lowDiskReserveBytes - 4
      }
    )
    addTeardownBlock { try await fixture.remove() }

    let saved = try await fixture.repository.save(
      sessionID: UUID(),
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Keep text under disk pressure."),
      sourceAudioURL: fixture.audioURL
    )

    XCTAssertEqual(saved.formattedText, "Keep text under disk pressure.")
    XCTAssertNil(saved.audioArtifact)
    XCTAssertEqual(saved.audioExpiredReason, .lowDisk)
  }

  func testRetentionInspectionFailureDoesNotFailCommittedCapture() async throws {
    let fixture = try Fixture(
      retentionSettings: .unlimited,
      availableCapacity: { _ in throw CocoaError(.fileReadUnknown) }
    )
    addTeardownBlock { try await fixture.remove() }

    let saved = try await fixture.repository.save(
      sessionID: UUID(),
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Committed before maintenance."),
      sourceAudioURL: fixture.audioURL
    )

    XCTAssertEqual(saved.formattedText, "Committed before maintenance.")
    XCTAssertNotNil(saved.audioArtifact)
  }

  func testUnavailableCapacityDoesNotFailCommitAndSurfacesMaintenance() async throws {
    let fixture = try Fixture(
      retentionSettings: .unlimited,
      availableCapacity: { _ in nil }
    )
    addTeardownBlock { try await fixture.remove() }

    let saved = try await fixture.repository.save(
      sessionID: UUID(),
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Capacity unavailable after commit."),
      sourceAudioURL: fixture.audioURL
    )

    XCTAssertNotNil(saved.audioArtifact)
    let maintenanceMessage =
      await fixture.repository.retentionMaintenanceMessage()
    XCTAssertEqual(
      maintenanceMessage,
      "History storage maintenance could not finish and will retry."
    )
  }

  func testFailedAudioDeletionRestoresTheArtifactForMaintenanceRetry() async throws {
    let fixture = try Fixture(
      retentionSettings: VoiceHistoryRetentionSettings(
        maximumAgeDays: nil,
        maximumAudioBytes: nil,
        maximumArtifactCount: 0
      ),
      removeRetainedAudio: { _ in throw CocoaError(.fileWriteUnknown) }
    )
    addTeardownBlock { try await fixture.remove() }

    let saved = try await fixture.repository.save(
      sessionID: UUID(),
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Retry failed cleanup."),
      sourceAudioURL: fixture.audioURL
    )

    XCTAssertNotNil(saved.audioArtifact)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: try XCTUnwrap(saved.audioArtifact?.url.path)
      )
    )
    do {
      _ = try await fixture.repository.enforceRetention(now: .now)
      XCTFail("Expected cleanup to remain retryable.")
    } catch {
      XCTAssertEqual(error as? VoiceInputHistoryError, .storageUnavailable)
    }
    let retained = try await fixture.repository.session(id: saved.id)
    XCTAssertNotNil(retained?.audioArtifact)
  }

  func testOwnedHistoryAudioUsesDataProtectionAndIsExcludedFromBackup() async throws {
    let fixture = try Fixture(retentionSettings: .unlimited)
    addTeardownBlock { try await fixture.remove() }

    let saved = try await fixture.repository.save(
      sessionID: UUID(),
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Protected local audio."),
      sourceAudioURL: fixture.audioURL
    )
    let audioURL = try XCTUnwrap(saved.audioArtifact?.url)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: audioURL.path
    )
    let values = try audioURL.resourceValues(forKeys: [.isExcludedFromBackupKey])

    // CoreSimulator omits this attribute even when the protection write succeeds.
    if let protection = attributes[.protectionKey] as? FileProtectionType {
      XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
    }
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  func testReloadPreservesUnknownFilesOutsideTheCanonicalRecoveryContract() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try await fixture.remove() }
    let audioDirectory = fixture.historyRoot.appendingPathComponent(
      "audio",
      isDirectory: true
    )
    let partial = audioDirectory.appendingPathComponent("stale.caf.partial")
    let orphan = audioDirectory.appendingPathComponent("orphan.caf")
    try Data("partial".utf8).write(to: partial)
    try Data("orphan".utf8).write(to: orphan)

    _ = try VoiceInputHistoryRepository(
      rootURL: fixture.historyRoot,
      retentionSettings: .iOSDefault
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
  }

  func testReloadRemovesAudioLeftAfterExpirationMetadataCommitted() async throws {
    let fixture = try Fixture(
      retentionSettings: VoiceHistoryRetentionSettings(
        maximumAgeDays: nil,
        maximumAudioBytes: nil,
        maximumArtifactCount: 0
      )
    )
    addTeardownBlock { try await fixture.remove() }
    let sessionID = UUID()
    _ = try await fixture.repository.save(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Transcript survives expiration."),
      sourceAudioURL: fixture.audioURL
    )
    let staleAudio = fixture.historyRoot
      .appendingPathComponent("audio", isDirectory: true)
      .appendingPathComponent("\(sessionID.uuidString.lowercased()).caf")
    try Data("stale-after-expiration".utf8).write(to: staleAudio)

    let reloaded = try VoiceInputHistoryRepository(
      rootURL: fixture.historyRoot,
      retentionSettings: .iOSDefault
    )
    _ = try await reloaded.recent(limit: 20)
    try await reloaded.close()

    XCTAssertFalse(FileManager.default.fileExists(atPath: staleAudio.path))
  }

  func testReloadPromotesAnInterruptedPartialToRecoveryHistory() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try await fixture.remove() }
    try await fixture.repository.close()
    let sessionID = UUID()
    let audioDirectory = fixture.historyRoot.appendingPathComponent(
      "audio",
      isDirectory: true
    )
    let partial = audioDirectory.appendingPathComponent(
      "\(sessionID.uuidString.lowercased()).partial"
    )
    try Data("recoverable-partial".utf8).write(to: partial)

    let reloaded = try VoiceInputHistoryRepository(
      rootURL: fixture.historyRoot,
      retentionSettings: .iOSDefault
    )
    addTeardownBlock { try await reloaded.close() }
    let sessions = try await reloaded.recent(limit: 20)
    let recovered = try XCTUnwrap(sessions.first)

    XCTAssertEqual(recovered.id, sessionID)
    XCTAssertEqual(recovered.recoveryReason, .processTermination)
    XCTAssertEqual(recovered.rawText, "")
    XCTAssertEqual(recovered.formattedText, "")
    XCTAssertNotNil(recovered.audioArtifact)
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertEqual(
      recovered.audioArtifact?.url.lastPathComponent,
      "\(sessionID.uuidString.lowercased()).caf"
    )
  }

  func testUnreadableCanonicalPartialDoesNotBlockValidHistory() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try await fixture.remove() }
    let completedID = UUID()
    _ = try await fixture.repository.save(
      sessionID: completedID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Valid history remains available."),
      sourceAudioURL: fixture.audioURL
    )
    try await fixture.repository.close()
    let invalidPartial = fixture.historyRoot
      .appendingPathComponent("audio", isDirectory: true)
      .appendingPathComponent("\(UUID().uuidString.lowercased()).partial")
    try Data().write(to: invalidPartial)

    let reloaded = try VoiceInputHistoryRepository(
      rootURL: fixture.historyRoot,
      retentionSettings: .iOSDefault
    )
    addTeardownBlock { try await reloaded.close() }
    let sessions = try await reloaded.recent(limit: 20)

    XCTAssertEqual(sessions.map(\.id), [completedID])
    XCTAssertTrue(FileManager.default.fileExists(atPath: invalidPartial.path))
  }

  func testRecoveredAudioExpiresAfterTwentyFourHoursWithoutDeletingHistory() async throws {
    let fixture = try Fixture(retentionSettings: .unlimited)
    addTeardownBlock { try await fixture.remove() }
    let sessionID = UUID()
    let endedAt = Date(timeIntervalSince1970: 20)
    _ = try await fixture.repository.saveRecovery(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: endedAt,
      reason: .audioInterruption,
      sourceAudioURL: fixture.audioURL
    )

    try await fixture.repository.enforceRetention(
      now: endedAt.addingTimeInterval(86_400)
    )
    let stored = try await fixture.repository.session(id: sessionID)
    let recovered = try XCTUnwrap(stored)

    XCTAssertNil(recovered.audioArtifact)
    XCTAssertEqual(recovered.audioExpiredReason, .recoveryLimit)
    XCTAssertEqual(recovered.recoveryReason, .audioInterruption)
  }

  func testRecoveryAfterCompletedCommitReturnsCompletedSessionAndRemovesPartial() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try await fixture.remove() }
    let sessionID = UUID()
    let completed = try await fixture.repository.save(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Committed before lifecycle interruption."),
      sourceAudioURL: fixture.audioURL
    )
    let latePartial = fixture.historyRoot
      .appendingPathComponent("audio", isDirectory: true)
      .appendingPathComponent("\(sessionID.uuidString.lowercased()).partial")
    try Data(contentsOf: fixture.audioURL).write(to: latePartial)

    let resolved = try await fixture.repository.saveRecovery(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 21),
      reason: .thermalPressure,
      sourceAudioURL: latePartial
    )

    XCTAssertEqual(resolved, completed)
    XCTAssertNil(resolved.recoveryReason)
    XCTAssertFalse(FileManager.default.fileExists(atPath: latePartial.path))
    let sessionCount = try await fixture.repository.recent(limit: 20).count
    XCTAssertEqual(sessionCount, 1)
  }

  func testRecoveryCollisionNeverDeletesAudioOutsideOwnedCapturePath() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try await fixture.remove() }
    let sessionID = UUID()
    _ = try await fixture.repository.save(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Existing completed session."),
      sourceAudioURL: fixture.audioURL
    )
    let unrelated = fixture.root.appendingPathComponent("unrelated.partial")
    try Data("must-remain".utf8).write(to: unrelated)

    do {
      _ = try await fixture.repository.saveRecovery(
        sessionID: sessionID,
        startedAt: Date(timeIntervalSince1970: 10),
        endedAt: Date(timeIntervalSince1970: 21),
        reason: .thermalPressure,
        sourceAudioURL: unrelated
      )
      XCTFail("A colliding recovery source outside owned capture storage must fail.")
    } catch {
      XCTAssertEqual(error as? VoiceInputHistoryError, .duplicateSession)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
  }

  func testRecoveryCollisionPreservesDifferingExactPartialForStartupRecovery() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try await fixture.remove() }
    let sessionID = UUID()
    _ = try await fixture.repository.save(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Existing completed session."),
      sourceAudioURL: fixture.audioURL
    )
    let differingPartial = fixture.historyRoot
      .appendingPathComponent("audio", isDirectory: true)
      .appendingPathComponent("\(sessionID.uuidString.lowercased()).partial")
    try Data("different-audio".utf8).write(to: differingPartial)

    do {
      _ = try await fixture.repository.saveRecovery(
        sessionID: sessionID,
        startedAt: Date(timeIntervalSince1970: 10),
        endedAt: Date(timeIntervalSince1970: 21),
        reason: .thermalPressure,
        sourceAudioURL: differingPartial
      )
      XCTFail("Differing audio must not be treated as a redundant committed partial.")
    } catch {
      XCTAssertEqual(error as? VoiceInputHistoryError, .duplicateSession)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: differingPartial.path))
  }

  func testReloadRemovesOnlyDigestIdenticalPartialLeftAfterCompletedCommit() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try await fixture.remove() }
    let sessionID = UUID()
    let completed = try await fixture.repository.save(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Completed before process termination."),
      sourceAudioURL: fixture.audioURL
    )
    try await fixture.repository.close()
    let redundantPartial = fixture.historyRoot
      .appendingPathComponent("audio", isDirectory: true)
      .appendingPathComponent("\(sessionID.uuidString.lowercased()).partial")
    try Data(contentsOf: fixture.audioURL).write(to: redundantPartial)

    let reloaded = try VoiceInputHistoryRepository(
      rootURL: fixture.historyRoot,
      retentionSettings: .iOSDefault
    )
    addTeardownBlock { try await reloaded.close() }
    let sessions = try await reloaded.recent(limit: 20)

    XCTAssertEqual(sessions, [completed])
    XCTAssertFalse(FileManager.default.fileExists(atPath: redundantPartial.path))
  }

  func testReloadRecoversDifferingPartialWhenSessionIdentifierAlreadyExists() async throws {
    let fixture = try Fixture()
    addTeardownBlock { try await fixture.remove() }
    let sessionID = UUID()
    let completed = try await fixture.repository.save(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try fixture.process("Existing session remains unchanged."),
      sourceAudioURL: fixture.audioURL
    )
    try await fixture.repository.close()
    let differingPartial = fixture.historyRoot
      .appendingPathComponent("audio", isDirectory: true)
      .appendingPathComponent("\(sessionID.uuidString.lowercased()).partial")
    try Data("different-recoverable-audio".utf8).write(to: differingPartial)

    let reloaded = try VoiceInputHistoryRepository(
      rootURL: fixture.historyRoot,
      retentionSettings: .iOSDefault
    )
    addTeardownBlock { try await reloaded.close() }
    let sessions = try await reloaded.recent(limit: 20)
    let recovered = try XCTUnwrap(sessions.first { $0.id != sessionID })

    XCTAssertEqual(sessions.count, 2)
    XCTAssertTrue(sessions.contains(completed))
    XCTAssertEqual(recovered.recoveryReason, .processTermination)
    XCTAssertFalse(FileManager.default.fileExists(atPath: differingPartial.path))
  }
}

private func setStoredSchemaRevision(
  _ revision: Int,
  databaseURL: URL
) throws {
  let database = try openDatabase(databaseURL)
  defer { sqlite3_close(database) }
  guard
    sqlite3_exec(
      database,
      "UPDATE voice_input_history SET schema_revision = \(revision);",
      nil,
      nil,
      nil
    ) == SQLITE_OK
  else {
    throw VoiceInputHistoryError.storageUnavailable
  }
}

private func storedSchemaRevision(databaseURL: URL) throws -> Int {
  let database = try openDatabase(databaseURL)
  defer { sqlite3_close(database) }
  var statement: OpaquePointer?
  guard
    sqlite3_prepare_v2(
      database,
      "SELECT schema_revision FROM voice_input_history LIMIT 1;",
      -1,
      &statement,
      nil
    ) == SQLITE_OK,
    let statement
  else {
    throw VoiceInputHistoryError.storageUnavailable
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW else {
    throw VoiceInputHistoryError.storageUnavailable
  }
  return Int(sqlite3_column_int(statement, 0))
}

private func openDatabase(_ databaseURL: URL) throws -> OpaquePointer {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(
      databaseURL.path,
      &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    ) == SQLITE_OK,
    let database
  else {
    if let database {
      sqlite3_close(database)
    }
    throw VoiceInputHistoryError.storageUnavailable
  }
  return database
}

private struct Fixture {
  let root: URL
  let historyRoot: URL
  let audioURL: URL
  let repository: VoiceInputHistoryRepository

  init(
    retentionSettings: VoiceHistoryRetentionSettings = .iOSDefault,
    availableCapacity: @escaping @Sendable (URL) throws -> Int64? = {
      _ in VoiceInputHistoryRepository.lowDiskReserveBytes
    },
    removeRetainedAudio: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.removeItem(at: $0)
    }
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    historyRoot = root.appendingPathComponent("history", isDirectory: true)
    audioURL = root.appendingPathComponent("source.caf")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    try Data("audio-1".utf8).write(to: audioURL)
    repository = try VoiceInputHistoryRepository(
      rootURL: historyRoot,
      retentionSettings: retentionSettings,
      availableCapacity: availableCapacity,
      removeRetainedAudio: removeRetainedAudio
    )
  }

  func process(_ text: String) throws -> VoiceInputProcessedTranscript {
    try VoiceInputDocumentPipeline().process(
      VoiceInputRawTranscript(
        text: text,
        segments: [
          VoiceInputTranscriptSegment(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: text
          )
        ],
        modelPackageID: "com.longdevity.whisper.tiny_en",
        modelVersion: "b4938"
      ),
      style: .natural
    )
  }

  func remove() async throws {
    try await repository.close()
    try FileManager.default.removeItem(at: root)
  }
}
