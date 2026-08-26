import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct SQLiteVoiceSessionStoreTest {
  @Test
  func storedDocumentIsReadableFromAReopenedHistory() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_reopen_\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
    }
    let sessionID = UUID()
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let first = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory
    )
    first.begin(sessionID: sessionID, startedAt: startedAt)
    try await first.complete(
      VoiceSessionDocument(
        id: sessionID,
        startedAt: startedAt,
        endedAt: Date(timeIntervalSince1970: 1_001),
        rawText: "raw",
        editedText: "edited",
        formattedText: "Formatted.",
        deliveredText: "Formatted.",
        targetApplicationName: "Notes",
        deliveryOutcome: .inserted
      )
    )

    let reopened = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory
    )
    let item = try #require(
      try await reopened.recentSessions(limit: 1).first
    )

    #expect(item.id == sessionID)
    #expect(item.formattedText == "Formatted.")
    #expect(item.audioArtifactURL == nil)
  }
}
