import Foundation
import HardwareControllerVoiceCore
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

private struct Fixture {
  let root: URL
  let historyRoot: URL
  let audioURL: URL
  let repository: VoiceInputHistoryRepository

  init(
    retentionSettings: VoiceHistoryRetentionSettings = .iOSDefault
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
      retentionSettings: retentionSettings
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
