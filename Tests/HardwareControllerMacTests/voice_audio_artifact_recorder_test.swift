import Foundation
import Testing

@testable import HardwareControllerMac

struct VoiceAudioArtifactRecorderTest {
  @Test
  func canceledSessionLeavesNoOwnedAudio() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_audio_cancel_\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
    }
    let history = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory
    )
    let sessionID = UUID()
    history.begin(sessionID: sessionID, startedAt: Date())
    history.append(try makeVoiceAudioFixture())

    await history.cancel(sessionID: sessionID)

    #expect(try await history.recentSessions(limit: 10).isEmpty)
    let audioDirectory = rootDirectory.appending(path: "audio")
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: audioDirectory,
        includingPropertiesForKeys: nil
      ).isEmpty
    )
  }
}
