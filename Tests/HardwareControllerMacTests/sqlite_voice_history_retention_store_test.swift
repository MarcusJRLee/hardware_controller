import AVFoundation
import Dispatch
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct SQLiteVoiceHistoryRetentionStoreTest {
  @Test
  func concurrentPinPreventsAStaleExpirationDecision() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "retention_pin_race_\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let history = try SQLiteVoiceSessionHistory(
      rootDirectory: root,
      retentionSettings: .unlimited
    )
    let document = retentionDocument(sessionID: sessionID)
    history.begin(sessionID: sessionID, startedAt: document.startedAt)
    history.append(try retentionAudioFixture())
    try await history.complete(document)
    let inspectionStarted = DispatchSemaphore(value: 0)
    let allowInspection = DispatchSemaphore(value: 0)
    let store = try SQLiteVoiceHistoryRetentionStore(
      databaseURL: root.appending(path: "history.sqlite3"),
      audioDirectory: root.appending(path: "audio"),
      artifactSize: { url in
        inspectionStarted.signal()
        guard allowInspection.wait(timeout: .now() + 2) == .success else {
          throw CocoaError(.fileReadUnknown)
        }
        return Int64(
          try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
      }
    )
    let maintenance = Task {
      try await store.enforce(
        settings: VoiceHistoryRetentionSettings(
          maximumAgeDays: nil,
          maximumAudioBytes: nil,
          maximumArtifactCount: 0
        ),
        now: Date(),
        activeSessionIDs: [],
        lowDiskReclaimBytes: 0
      )
    }
    let inspectionDidStart = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(
          returning:
            inspectionStarted.wait(timeout: .now() + 2) == .success
        )
      }
    }
    guard inspectionDidStart else {
      allowInspection.signal()
      throw VoiceSessionHistoryError.storageUnavailable(
        "The retention test did not reach artifact inspection."
      )
    }

    do {
      try await history.setPinned(sessionID: sessionID, isPinned: true)
    } catch {
      allowInspection.signal()
      throw error
    }
    allowInspection.signal()
    let report = try await maintenance.value

    #expect(report.expired.isEmpty)
    #expect(report.issues == [.removalFailed(sessionID: sessionID)])
    let retained = try #require(try await history.session(id: sessionID))
    #expect(retained.isPinned)
    #expect(retained.audioArtifactURL != nil)
    #expect(retained.audioExpirationReason == nil)
  }

  @Test
  func capacityFailureIsReportedWithoutBlockingQuotaCleanup() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "retention_capacity_\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    var history: SQLiteVoiceSessionHistory? = try SQLiteVoiceSessionHistory(
      rootDirectory: root,
      retentionSettings: .unlimited
    )
    let activeHistory = try #require(history)
    let document = retentionDocument(sessionID: sessionID)
    activeHistory.begin(
      sessionID: sessionID,
      startedAt: document.startedAt
    )
    activeHistory.append(try retentionAudioFixture())
    try await activeHistory.complete(document)
    history = nil
    let store = try SQLiteVoiceHistoryRetentionStore(
      databaseURL: root.appending(path: "history.sqlite3"),
      audioDirectory: root.appending(path: "audio"),
      availableCapacity: { _ in throw CocoaError(.fileReadUnknown) }
    )

    let report = try await store.enforce(
      settings: VoiceHistoryRetentionSettings(
        maximumAgeDays: nil,
        maximumAudioBytes: nil,
        maximumArtifactCount: 0
      ),
      now: Date(),
      activeSessionIDs: [],
      lowDiskReclaimBytes: 0
    )

    #expect(report.expired.map(\.sessionID) == [sessionID])
    #expect(
      report.issues == [
        .maintenanceUnavailable(
          "Voice History could not inspect available disk capacity."
        )
      ]
    )
  }

  @Test
  func missingArtifactIsReportedWithoutChangingSessionMetadata()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "retention_missing_\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    var history: SQLiteVoiceSessionHistory? = try SQLiteVoiceSessionHistory(
      rootDirectory: root,
      retentionSettings: .unlimited
    )
    let document = VoiceSessionDocument(
      id: sessionID,
      startedAt: Date().addingTimeInterval(-1),
      endedAt: Date(),
      rawText: "Retain the text.",
      editedText: "Retain the text.",
      formattedText: "Retain the text.",
      deliveredText: "Retain the text.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted
    )
    let activeHistory = try #require(history)
    activeHistory.begin(
      sessionID: sessionID,
      startedAt: document.startedAt
    )
    activeHistory.append(try retentionAudioFixture())
    try await activeHistory.complete(document)
    let audioURL = try #require(
      try await activeHistory.session(id: sessionID)?.audioArtifactURL
    )
    try FileManager.default.removeItem(at: audioURL)
    history = nil
    let store = try SQLiteVoiceHistoryRetentionStore(
      databaseURL: root.appending(path: "history.sqlite3"),
      audioDirectory: root.appending(path: "audio")
    )

    let report = try await store.enforce(
      settings: VoiceHistoryRetentionSettings(
        maximumAgeDays: nil,
        maximumAudioBytes: nil,
        maximumArtifactCount: 0
      ),
      now: Date(),
      activeSessionIDs: [],
      lowDiskReclaimBytes: 0
    )

    #expect(report.expired.isEmpty)
    #expect(report.issues == [.missingArtifact(sessionID: sessionID)])
    let reopened = try SQLiteVoiceSessionHistory(rootDirectory: root)
    let retained = try #require(try await reopened.session(id: sessionID))
    #expect(retained.rawText == "Retain the text.")
    #expect(retained.audioExpirationReason == nil)
  }

  private func retentionAudioFixture() throws -> CapturedAudioBuffer {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: 1_600
      )
    else {
      throw MicrophoneCaptureError.invalidBuffer("Fixture failed.")
    }
    buffer.frameLength = 1_600
    return try CapturedAudioBuffer(copying: buffer)
  }

  private func retentionDocument(sessionID: UUID) -> VoiceSessionDocument {
    let endedAt = Date()
    return VoiceSessionDocument(
      id: sessionID,
      startedAt: endedAt.addingTimeInterval(-1),
      endedAt: endedAt,
      rawText: "Keep raw text.",
      editedText: "Keep edited text.",
      formattedText: "Keep formatted text.",
      deliveredText: "Keep delivered text.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted
    )
  }
}
