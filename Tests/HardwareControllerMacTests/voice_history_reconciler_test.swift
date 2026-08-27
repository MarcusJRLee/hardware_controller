@preconcurrency import AVFoundation
import Foundation
import HardwareControllerCore
import SQLite3
import Testing

@testable import HardwareControllerMac

struct VoiceHistoryReconcilerTest {
  @Test
  func startupRecoversAnInterruptedCaptureWithoutInventingText() async throws {
    let root = temporaryRoot("partial")
    defer { try? FileManager.default.removeItem(at: root) }
    let originalID = UUID()
    var initialized: SQLiteVoiceSessionHistory? = try SQLiteVoiceSessionHistory(
      rootDirectory: root
    )
    #expect(initialized != nil)
    initialized = nil
    let finalURL = try await recordFixture(
      sessionID: originalID,
      audioDirectory: root.appending(path: "audio")
    )
    let partialURL = finalURL.deletingPathExtension().appendingPathExtension(
      "partial"
    )
    try FileManager.default.moveItem(at: finalURL, to: partialURL)

    let history = try SQLiteVoiceSessionHistory(rootDirectory: root)
    let item = try #require(try await history.recentSessions(limit: 10).first)

    #expect(item.id == originalID)
    #expect(item.recoveryKind == .interruptedCapture)
    #expect(item.recoveredAt != nil)
    #expect(item.deliveryOutcome == .notAttempted)
    #expect(item.results.count == 4)
    #expect(item.results.allSatisfy { $0.text.isEmpty })
    #expect(item.audioArtifactURL?.lastPathComponent == "\(originalID).caf")
    #expect(!FileManager.default.fileExists(atPath: partialURL.path))
    #expect(
      history.latestRecoveryReport()?.completedActions
        == [
          .recover(
            filename: "\(originalID).partial",
            preferredSessionID: originalID,
            kind: .interruptedCapture
          )
        ]
    )

    let retranscription = try await VoiceHistoryService(
      history: history,
      transcriber: RecoveryHistoryTranscriber(),
      reformatter: UnusedRecoveryHistoryReformatter(),
      redeliverer: UnusedRecoveryHistoryRedeliverer()
    ).retranscribe(sessionID: originalID)
    #expect(retranscription.text == "Recovered transcript.")
    #expect(retranscription.origin == .retranscription)
    #expect(
      try await history.session(id: originalID)?.results.count == 5
    )
  }

  @Test
  func startupRestoresAnInterruptedExpiration() async throws {
    let root = temporaryRoot("expiration_restore")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let document = historyDocument(sessionID: sessionID)
    let finalURL = try await insertFixture(document, root: root)
    let quarantineFilename =
      ".expiring_\(sessionID.uuidString)_\(UUID().uuidString).caf"
    let quarantineURL = root.appending(path: "audio/\(quarantineFilename)")
    try FileManager.default.moveItem(at: finalURL, to: quarantineURL)
    let reopened = try SQLiteVoiceSessionHistory(rootDirectory: root)
    let item = try #require(try await reopened.session(id: sessionID))

    #expect(item.recoveryKind == nil)
    #expect(item.audioArtifactURL == finalURL)
    #expect(!FileManager.default.fileExists(atPath: quarantineURL.path))
    #expect(
      reopened.latestRecoveryReport()?.completedActions
        == [
          .restoreQuarantine(
            filename: quarantineFilename,
            destinationFilename: "\(sessionID).caf",
            sessionID: sessionID
          )
        ]
    )
  }

  @Test
  func retentionReconcilesInterruptedExpirationBeforeEnforcement() async throws {
    let root = temporaryRoot("expiration_before_retention")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    var initialized: SQLiteVoiceSessionHistory? = try SQLiteVoiceSessionHistory(
      rootDirectory: root
    )
    #expect(initialized != nil)
    initialized = nil
    let databaseURL = root.appending(path: "history.sqlite3")
    let audioDirectory = root.appending(path: "audio")
    let finalURL = try await recordFixture(
      sessionID: sessionID,
      audioDirectory: audioDirectory
    )
    let store = try SQLiteVoiceSessionStore(
      databaseURL: databaseURL,
      audioDirectory: audioDirectory
    )
    try await store.insert(
      historyDocument(sessionID: sessionID),
      audioURL: finalURL
    )
    let quarantineFilename =
      ".expiring_\(sessionID.uuidString)_\(UUID().uuidString).caf"
    let quarantineURL = root.appending(path: "audio/\(quarantineFilename)")
    try FileManager.default.moveItem(at: finalURL, to: quarantineURL)

    let reopened = try SQLiteVoiceSessionHistory(rootDirectory: root)
    let report = try await reopened.setRetentionSettings(
      VoiceHistoryRetentionSettings(
        maximumAgeDays: nil,
        maximumAudioBytes: 0,
        maximumArtifactCount: nil
      )
    )

    #expect(report.expired.map(\.sessionID) == [sessionID])
    #expect(report.issues.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: quarantineURL.path))
    #expect(
      reopened.latestRecoveryReport()?.completedActions
        == [
          .restoreQuarantine(
            filename: quarantineFilename,
            destinationFilename: "\(sessionID).caf",
            sessionID: sessionID
          )
        ]
    )
  }

  @Test
  func corruptSessionDoesNotHideUnrelatedHistory() async throws {
    let root = temporaryRoot("corrupt_row")
    defer { try? FileManager.default.removeItem(at: root) }
    let validID = UUID()
    let corruptID = UUID()
    _ = try await insertFixture(
      historyDocument(sessionID: validID),
      root: root
    )
    _ = try await insertFixture(
      historyDocument(sessionID: corruptID),
      root: root
    )
    try executeSQL(
      "UPDATE voice_sessions SET delivery_outcome = 'invalid', ended_at = 2000 "
        + "WHERE id = '\(corruptID.uuidString)';",
      root: root
    )

    let reopened = try SQLiteVoiceSessionHistory(rootDirectory: root)
    let items = try await reopened.recentSessions(limit: 1)

    #expect(items.map(\.id) == [validID])
    #expect(
      reopened.latestRecoveryReport()?.issues.contains(
        .invalidSessionRecord
      ) == true
    )
  }

  @Test
  func committedExpirationDiscardsItsQuarantine() async throws {
    let root = temporaryRoot("expiration_discard")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let finalURL = try await insertFixture(
      historyDocument(sessionID: sessionID),
      root: root
    )
    let quarantineFilename =
      ".expiring_\(sessionID.uuidString)_\(UUID().uuidString).caf"
    let quarantineURL = root.appending(path: "audio/\(quarantineFilename)")
    try FileManager.default.moveItem(at: finalURL, to: quarantineURL)
    try executeSQL(
      """
      UPDATE voice_sessions
      SET audio_filename = NULL, audio_expired_at = 2000,
        audio_expiration_reason = 'byte_limit'
      WHERE id = '\(sessionID.uuidString)';
      """,
      root: root
    )

    let reopened = try SQLiteVoiceSessionHistory(rootDirectory: root)
    let item = try #require(try await reopened.session(id: sessionID))

    #expect(item.audioArtifactURL == nil)
    #expect(item.audioExpirationReason == .byteLimit)
    #expect(!FileManager.default.fileExists(atPath: quarantineURL.path))
    #expect(
      reopened.latestRecoveryReport()?.completedActions
        == [.discardCommittedQuarantine(filename: quarantineFilename)]
    )
  }

  @Test
  func unreadableOwnedArtifactsAreBoundedWithoutBlockingLaunch() async throws {
    let root = temporaryRoot("unreadable")
    defer { try? FileManager.default.removeItem(at: root) }
    var initialized: SQLiteVoiceSessionHistory? = try SQLiteVoiceSessionHistory(
      rootDirectory: root
    )
    #expect(initialized != nil)
    initialized = nil
    let audioDirectory = root.appending(path: "audio")
    let recentFilename = "\(UUID().uuidString).partial"
    let staleFilename = "\(UUID().uuidString).caf"
    let recentURL = audioDirectory.appending(path: recentFilename)
    let staleURL = audioDirectory.appending(path: staleFilename)
    try Data("not audio".utf8).write(to: recentURL)
    try Data("not audio".utf8).write(to: staleURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-86_401)],
      ofItemAtPath: staleURL.path
    )

    let history = try SQLiteVoiceSessionHistory(rootDirectory: root)
    #expect(try await history.recentSessions(limit: 10).isEmpty)

    #expect(FileManager.default.fileExists(atPath: recentURL.path))
    #expect(!FileManager.default.fileExists(atPath: staleURL.path))
    #expect(
      history.latestRecoveryReport()?.issues.contains(
        .unreadableArtifact(filename: recentFilename)
      ) == true
    )
  }

  @Test
  func oneFailedRepairDoesNotBlockAnUnrelatedRecovery() async throws {
    let root = temporaryRoot("independent_actions")
    defer { try? FileManager.default.removeItem(at: root) }
    let retainedID = UUID()
    let partialID = UUID()
    let retainedURL = try await insertFixture(
      historyDocument(sessionID: retainedID),
      root: root
    )
    let quarantineFilename =
      ".expiring_\(retainedID.uuidString)_\(UUID().uuidString).caf"
    try FileManager.default.copyItem(
      at: retainedURL,
      to: root.appending(path: "audio/\(quarantineFilename)")
    )
    let partialFinalURL = try await recordFixture(
      sessionID: partialID,
      audioDirectory: root.appending(path: "audio")
    )
    try FileManager.default.moveItem(
      at: partialFinalURL,
      to: partialFinalURL.deletingPathExtension().appendingPathExtension(
        "partial"
      )
    )
    let reopened = try SQLiteVoiceSessionHistory(rootDirectory: root)
    let sessions = try await reopened.recentSessions(limit: 10)

    #expect(Set(sessions.map(\.id)) == Set([retainedID, partialID]))
    #expect(
      sessions.first(where: { $0.id == partialID })?.recoveryKind
        == .interruptedCapture
    )
    #expect(
      reopened.latestRecoveryReport()?.issues.contains(
        .actionFailed(filename: quarantineFilename)
      ) == true
    )
  }

  @Test
  func recoveredAudioExpiresAfterTwentyFourHoursButSessionRemains()
    async throws
  {
    let root = temporaryRoot("recovery_expiration")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    var initialized: SQLiteVoiceSessionHistory? = try SQLiteVoiceSessionHistory(
      rootDirectory: root
    )
    #expect(initialized != nil)
    initialized = nil
    let finalURL = try await recordFixture(
      sessionID: sessionID,
      audioDirectory: root.appending(path: "audio")
    )
    let partialURL = finalURL.deletingPathExtension().appendingPathExtension(
      "partial"
    )
    try FileManager.default.moveItem(at: finalURL, to: partialURL)
    var firstRecovery: SQLiteVoiceSessionHistory? = try SQLiteVoiceSessionHistory(
      rootDirectory: root
    )
    _ = try await firstRecovery?.recentSessions(limit: 10)
    firstRecovery = nil
    let oldRecovery = Date().addingTimeInterval(-86_401).timeIntervalSince1970
    try executeSQL(
      """
      UPDATE voice_sessions
      SET started_at = \(oldRecovery - 2), ended_at = \(oldRecovery - 1),
        recovered_at = \(oldRecovery)
      WHERE id = '\(sessionID.uuidString)';
      """,
      root: root
    )

    let reopened = try SQLiteVoiceSessionHistory(rootDirectory: root)
    let item = try #require(try await reopened.session(id: sessionID))

    #expect(item.recoveryKind == .interruptedCapture)
    #expect(item.recoveredAt?.timeIntervalSince1970 == oldRecovery)
    #expect(
      reopened.latestRetentionReport()?.expired.map(\.reason)
        == [.recoveryLimit]
    )
    #expect(reopened.latestRetentionReport()?.issues == [])
    #expect(item.audioArtifactURL == nil)
    #expect(item.audioExpirationReason == .recoveryLimit)
    #expect(item.results.count == 4)
  }

  @Test
  func audioFinalizationFailureStillStoresTranscriptEvidence() async throws {
    let root = temporaryRoot("full_disk")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let history = try SQLiteVoiceSessionHistory(
      rootDirectory: root,
      retentionSettings: .unlimited,
      recorderFactory: { _, _ in FailingVoiceAudioRecorder() }
    )
    let document = historyDocument(sessionID: sessionID)
    history.begin(sessionID: sessionID, startedAt: document.startedAt)

    await #expect(throws: VoiceSessionHistoryError.audioUnavailable("Disk full.")) {
      try await history.complete(document)
    }

    let stored = try #require(try await history.session(id: sessionID))
    #expect(stored.document == document)
    #expect(stored.audioArtifactURL == nil)
    #expect(stored.results.count == 4)
  }

  @Test
  func corruptDatabaseFileIsPreservedAndDoesNotBlockHistoryLaunch()
    async throws
  {
    let root = temporaryRoot("corrupt_database")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let databaseURL = root.appending(path: "history.sqlite3")
    let corruptData = Data("not a sqlite database".utf8)
    let walData = Data("preserved wal".utf8)
    let shmData = Data("present shm".utf8)
    try corruptData.write(to: databaseURL)
    try walData.write(to: URL(fileURLWithPath: databaseURL.path + "-wal"))
    try shmData.write(to: URL(fileURLWithPath: databaseURL.path + "-shm"))

    let history = try SQLiteVoiceSessionHistory(rootDirectory: root)

    #expect(try await history.recentSessions(limit: 10).isEmpty)
    #expect(
      history.latestRecoveryReport()?.issues.contains(where: {
        if case .databaseRebuilt = $0 { true } else { false }
      }) == true
    )
    let contents = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    )
    let preserved = contents.filter {
      $0.lastPathComponent.hasPrefix("history_corrupt_")
        && $0.pathExtension == "sqlite3"
    }
    #expect(preserved.count == 1)
    let preservedDatabase = try #require(preserved.first)
    #expect(try Data(contentsOf: preservedDatabase) == corruptData)
    #expect(
      try Data(
        contentsOf: URL(fileURLWithPath: preservedDatabase.path + "-wal")
      ) == walData
    )
    #expect(
      FileManager.default.fileExists(
        atPath: preservedDatabase.path + "-shm"
      )
    )
  }

  /// Inserts crash-test evidence without starting live maintenance tasks.
  private func insertFixture(
    _ document: VoiceSessionDocument,
    root: URL
  ) async throws -> URL {
    let audioDirectory = root.appending(path: "audio")
    try FileManager.default.createDirectory(
      at: audioDirectory,
      withIntermediateDirectories: true
    )
    let audioURL = try await recordFixture(
      sessionID: document.id,
      audioDirectory: audioDirectory
    )
    let store = try SQLiteVoiceSessionStore(
      databaseURL: root.appending(path: "history.sqlite3"),
      audioDirectory: audioDirectory
    )
    try await store.insert(document, audioURL: audioURL)
    return audioURL
  }

  private func recordFixture(
    sessionID: UUID,
    audioDirectory: URL
  ) async throws -> URL {
    let recorder = VoiceAudioArtifactRecorder(
      sessionID: sessionID,
      audioDirectory: audioDirectory
    )
    recorder.append(try makeVoiceAudioFixture())
    return try #require(try await recorder.finishRetainingAudio())
  }

  private func historyDocument(sessionID: UUID) -> VoiceSessionDocument {
    VoiceSessionDocument(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 1_000),
      endedAt: Date(timeIntervalSince1970: 1_001),
      rawText: "raw text",
      editedText: "edited text",
      formattedText: "Formatted text.",
      deliveredText: "Formatted text.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted
    )
  }

  private func executeSQL(_ sql: String, root: URL) throws {
    var database: OpaquePointer?
    guard
      sqlite3_open(root.appending(path: "history.sqlite3").path, &database)
        == SQLITE_OK,
      let database
    else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "The test database could not be opened."
      )
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "The test database could not be updated."
      )
    }
  }

  private func temporaryRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "voice_history_recovery_\(label)_\(UUID().uuidString)"
    )
  }
}

private final class FailingVoiceAudioRecorder:
  VoiceAudioArtifactRecording,
  @unchecked Sendable
{
  func append(_ audio: CapturedAudioBuffer) {}
  func stopRetainingAudio() {}

  func finishRetainingAudio() async throws -> URL? {
    throw VoiceSessionHistoryError.audioUnavailable("Disk full.")
  }

  func discard() async {}
}

private struct RecoveryHistoryTranscriber: VoiceHistoryAudioTranscribing {
  func transcribe(
    audioURL: URL,
    locale: Locale
  ) async throws -> VoiceHistoryTranscription {
    VoiceHistoryTranscription(
      text: "Recovered transcript.",
      spans: [
        VoiceHistoryTimedSpan(
          startMilliseconds: 0,
          endMilliseconds: 100,
          text: "Recovered transcript."
        )
      ]
    )
  }
}

private struct UnusedRecoveryHistoryReformatter: VoiceHistoryReformatting {
  func reformat(
    text: String,
    sessionID: UUID,
    style: VoiceStyle
  ) async throws -> VoiceHistoryReformat {
    throw VoiceHistoryServiceError.noReusableText
  }
}

private struct UnusedRecoveryHistoryRedeliverer: VoiceHistoryRedelivering {
  func redeliver(_ text: String) async throws {
    throw VoiceHistoryServiceError.noReusableText
  }
}
