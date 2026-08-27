import Foundation
import XCTest

@testable import VoiceInput

final class VoiceInputHistoryAudioPlayerModelTest: XCTestCase {
  @MainActor
  func testPlayAndSecondTapStopTheSameRetainedRecording() throws {
    let player = RecordingAudioPlayer()
    let model = VoiceInputHistoryAudioPlayerModel(player: player)
    let session = try Self.sessionWithAudio()

    model.toggle(session)
    XCTAssertEqual(model.playingSessionID, session.id)
    XCTAssertEqual(player.playedURLs, [session.audioArtifact?.url].compactMap { $0 })

    model.toggle(session)
    XCTAssertNil(model.playingSessionID)
    XCTAssertEqual(player.stopCount, 1)
  }

  @MainActor
  func testExpiredAudioCannotStartPlayback() throws {
    let player = RecordingAudioPlayer()
    let model = VoiceInputHistoryAudioPlayerModel(player: player)
    let retained = try Self.sessionWithAudio()
    let expired = retained.expiringAudio(at: .now, reason: .ageLimit)

    model.toggle(expired)

    XCTAssertTrue(player.playedURLs.isEmpty)
    XCTAssertNotNil(model.errorMessage)
  }

  @MainActor
  func testNaturalPlaybackCompletionClearsThePlayingSession() throws {
    let player = RecordingAudioPlayer()
    let model = VoiceInputHistoryAudioPlayerModel(player: player)
    let session = try Self.sessionWithAudio()

    model.toggle(session)
    player.finish()

    XCTAssertNil(model.playingSessionID)
  }

  private static func sessionWithAudio() throws -> VoiceInputHistorySession {
    let raw = VoiceInputRawTranscript(
      text: "Recorded thought.",
      segments: [],
      modelPackageID: "whisper",
      modelVersion: "1"
    )
    let processed = try VoiceInputDocumentPipeline().process(raw, style: .natural)
    return VoiceInputHistorySession(
      id: UUID(),
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: processed,
      audioArtifact: VoiceInputHistoryAudioArtifact(
        url: URL(fileURLWithPath: "/private/recording.caf"),
        byteCount: 10,
        sha256: String(repeating: "a", count: 64)
      )
    )
  }
}

@MainActor
private final class RecordingAudioPlayer: VoiceInputHistoryAudioPlaying {
  var completionHandler: (@MainActor @Sendable () -> Void)?
  private(set) var playedURLs: [URL] = []
  private(set) var stopCount = 0

  func play(url: URL) throws {
    playedURLs.append(url)
  }

  func stop() {
    stopCount += 1
  }

  func finish() {
    completionHandler?()
  }
}
