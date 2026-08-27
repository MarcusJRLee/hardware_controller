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

  func testReloadRemovesIncompleteAndUnreferencedAudioArtifacts() async throws {
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

    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
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
    try await reloaded.close()

    XCTAssertFalse(FileManager.default.fileExists(atPath: staleAudio.path))
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
