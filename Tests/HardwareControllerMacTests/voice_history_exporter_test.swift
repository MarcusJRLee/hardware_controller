import CryptoKit
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct VoiceHistoryExporterTest {
  @Test
  func exportContainsSessionEvidenceAudioAndVerifiedChecksums()
    async throws
  {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_export_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let history = try SQLiteVoiceSessionHistory(
      rootDirectory: root.appending(path: "source")
    )
    let sessionID = UUID()
    let document = VoiceSessionDocument(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 1_000),
      endedAt: Date(timeIntervalSince1970: 1_001),
      rawText: "raw",
      editedText: "edited",
      formattedText: "Formatted.",
      deliveredText: "Formatted.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted
    )
    history.begin(sessionID: sessionID, startedAt: document.startedAt)
    history.append(try makeVoiceAudioFixture())
    try await history.complete(document)
    let session = try #require(try await history.session(id: sessionID))
    let destination = root.appending(path: "session.voice_history")
    let exporter = VoiceHistoryExporter(
      now: { Date(timeIntervalSince1970: 2_000) }
    )

    try await exporter.export(session, to: destination)

    let data = try Data(
      contentsOf: destination.appending(path: "session.json")
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(
      VoiceHistoryExportSession.self,
      from: data
    )
    let checksumData = try Data(
      contentsOf: destination.appending(path: "checksums.json")
    )
    let checksums = try decoder.decode(
      VoiceHistoryExportChecksums.self,
      from: checksumData
    )
    #expect(manifest.schemaRevision == 3)
    #expect(manifest.document == document)
    #expect(manifest.results.count == 4)
    #expect(manifest.audioFilename == "audio.caf")
    #expect(manifest.audioDurationMilliseconds == 100)
    #expect(manifest.audioExpiredAt == nil)
    #expect(manifest.audioExpirationReason == nil)
    #expect(manifest.recoveryKind == nil)
    #expect(manifest.recoveredAt == nil)
    #expect(checksums.algorithm == "SHA-256")
    #expect(
      checksums.files["session.json"]
        == SHA256.hash(data: data).map {
          String(format: "%02x", $0)
        }.joined()
    )
    #expect(checksums.files["audio.caf"]?.count == 64)
    #expect(
      FileManager.default.fileExists(
        atPath: destination.appending(path: "audio.caf").path
      )
    )
    #expect(try await history.session(id: sessionID) == session)
  }

  @Test
  func exportPreservesRecoveryProvenance() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_recovery_export_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let recoveredAt = Date(timeIntervalSince1970: 2_000)
    let item = VoiceSessionHistoryItem(
      document: VoiceSessionDocument(
        id: sessionID,
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_001),
        rawText: "",
        editedText: "",
        formattedText: "",
        deliveredText: "",
        targetApplicationName: nil,
        deliveryOutcome: .notAttempted
      ),
      audioArtifactURL: nil,
      audioDurationMilliseconds: 100,
      recoveryKind: .interruptedCapture,
      recoveredAt: recoveredAt
    )

    try await VoiceHistoryExporter().export(item, to: root)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(
      VoiceHistoryExportSession.self,
      from: Data(contentsOf: root.appending(path: "session.json"))
    )
    #expect(manifest.schemaRevision == 3)
    #expect(manifest.recoveryKind == .interruptedCapture)
    #expect(manifest.recoveredAt == recoveredAt)
  }

  @Test
  func exportPreservesAudioExpirationEvidenceWithoutAudio() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_expired_export_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source")
    let history = try SQLiteVoiceSessionHistory(
      rootDirectory: source,
      retentionSettings: .unlimited
    )
    let sessionID = UUID()
    let document = VoiceSessionDocument(
      id: sessionID,
      startedAt: Date(),
      endedAt: Date(),
      rawText: "raw",
      editedText: "raw",
      formattedText: "Raw.",
      deliveredText: "Raw.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted
    )
    history.begin(sessionID: sessionID, startedAt: document.startedAt)
    history.append(try makeVoiceAudioFixture())
    try await history.complete(document)
    _ = try await history.setRetentionSettings(
      VoiceHistoryRetentionSettings(
        maximumAgeDays: nil,
        maximumAudioBytes: nil,
        maximumArtifactCount: 0
      )
    )
    let session = try #require(try await history.session(id: sessionID))
    let destination = root.appending(path: "expired.voice_history")

    try await VoiceHistoryExporter().export(session, to: destination)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(
      VoiceHistoryExportSession.self,
      from: Data(
        contentsOf: destination.appending(path: "session.json")
      )
    )
    #expect(manifest.audioFilename == nil)
    #expect(manifest.audioExpiredAt != nil)
    #expect(manifest.audioExpirationReason == .artifactLimit)
    #expect(
      !FileManager.default.fileExists(
        atPath: destination.appending(path: "audio.caf").path
      )
    )
  }
}
