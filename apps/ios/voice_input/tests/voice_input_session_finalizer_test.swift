import Foundation
import HardwareControllerVoiceCore
import Synchronization
import XCTest

@testable import VoiceInput

final class VoiceInputSessionFinalizerTest: XCTestCase {
  func testReturnsFormattedTextOnlyAfterHistoryAcceptsEveryStage() async throws {
    let history = RecordingHistoryStore()
    let finalizer = VoiceInputSessionFinalizer(
      history: history,
      style: .technical
    )
    let sessionID = UUID()
    let audioURL = URL(fileURLWithPath: "/private/session.caf")
    let raw = VoiceInputRawTranscript(
      text:
        "Intro new paragraph start a numbered list Run Git new paragraph Run Bash end list Done",
      segments: [],
      modelPackageID: "whisper",
      modelVersion: "1"
    )

    let result = try await finalizer.finalize(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      rawTranscript: raw,
      sourceAudioURL: audioURL
    )

    XCTAssertEqual(
      result.formattedText,
      "Intro\n\n1. Run Git\n2. Run Bash\n\nDone"
    )
    XCTAssertEqual(result.formattedDocument.style, .technical)
    let call = try XCTUnwrap(history.calls.first)
    XCTAssertEqual(call.sessionID, sessionID)
    XCTAssertEqual(call.transcript, result)
    XCTAssertEqual(call.sourceAudioURL, audioURL)
  }
}

private final class RecordingHistoryStore: VoiceInputHistoryStoring, Sendable {
  struct Call: Sendable {
    let sessionID: UUID
    let transcript: VoiceInputProcessedTranscript
    let sourceAudioURL: URL
  }

  private let state = Mutex<[Call]>([])

  var calls: [Call] { state.withLock { $0 } }

  func save(
    sessionID: UUID,
    startedAt: Date,
    endedAt: Date,
    transcript: VoiceInputProcessedTranscript,
    sourceAudioURL: URL
  ) async throws -> VoiceInputHistorySession {
    state.withLock {
      $0.append(
        Call(
          sessionID: sessionID,
          transcript: transcript,
          sourceAudioURL: sourceAudioURL
        )
      )
    }
    return VoiceInputHistorySession(
      id: sessionID,
      startedAt: startedAt,
      endedAt: endedAt,
      transcript: transcript,
      audioArtifact: nil
    )
  }
}
