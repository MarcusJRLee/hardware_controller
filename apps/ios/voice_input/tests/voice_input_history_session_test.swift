import Foundation
import XCTest

@testable import VoiceInput

final class VoiceInputHistorySessionTest: XCTestCase {
  func testValidationRejectsAudioOutsideTheOwnedHistoryDirectory() throws {
    let sessionID = UUID()
    let ownedAudioDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let session = try Self.session(
      id: sessionID,
      audioURL:
        ownedAudioDirectory
        .deletingLastPathComponent()
        .appendingPathComponent("outside.caf")
    )

    XCTAssertThrowsError(
      try session.validated(audioDirectoryURL: ownedAudioDirectory)
    )
  }

  func testExpiredAudioRetainsAValidSearchableSession() throws {
    let sessionID = UUID()
    let audioDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let session = try Self.session(
      id: sessionID,
      audioURL: audioDirectory.appendingPathComponent(
        "\(sessionID.uuidString.lowercased()).caf"
      )
    )

    let expired =
      try session
      .expiringAudio(at: Date(timeIntervalSince1970: 30), reason: .ageLimit)
      .validated(audioDirectoryURL: audioDirectory)

    XCTAssertNil(expired.audioArtifact)
    XCTAssertEqual(expired.audioExpiredReason, .ageLimit)
    XCTAssertEqual(expired.formattedText, "Owned paths only.")
  }

  func testRevisionOnePayloadMigratesWithoutInventingRecoveryState() throws {
    let sessionID = UUID()
    let audioDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let session = try Self.session(
      id: sessionID,
      audioURL: audioDirectory.appendingPathComponent(
        "\(sessionID.uuidString.lowercased()).caf"
      )
    )
    let encoded = try JSONEncoder().encode(session)
    var payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    payload["schemaRevision"] = 1
    payload.removeValue(forKey: "recoveryReason")

    let migrated = try JSONDecoder().decode(
      VoiceInputHistorySession.self,
      from: JSONSerialization.data(withJSONObject: payload)
    )

    XCTAssertEqual(migrated.schemaRevision, 2)
    XCTAssertNil(migrated.recoveryReason)
    XCTAssertEqual(migrated.formattedText, session.formattedText)
  }

  func testRecoveryPresentationExplainsWhyTranscriptIsUnavailable() throws {
    let sessionID = UUID()
    let recovered = VoiceInputHistorySession(
      recoveryID: sessionID,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      reason: .audioRouteChange,
      audioArtifact: VoiceInputHistoryAudioArtifact(
        url: FileManager.default.temporaryDirectory.appendingPathComponent(
          "\(sessionID.uuidString.lowercased()).caf"
        ),
        byteCount: 7,
        sha256: String(repeating: "a", count: 64)
      )
    )

    XCTAssertTrue(recovered.isRecovery)
    XCTAssertEqual(
      recovered.recoveryDescription,
      "An audio route change stopped capture before transcription."
    )
  }

  private static func session(
    id: UUID,
    audioURL: URL
  ) throws -> VoiceInputHistorySession {
    let raw = VoiceInputRawTranscript(
      text: "Owned paths only.",
      segments: [],
      modelPackageID: "whisper",
      modelVersion: "1"
    )
    return VoiceInputHistorySession(
      id: id,
      startedAt: Date(timeIntervalSince1970: 10),
      endedAt: Date(timeIntervalSince1970: 20),
      transcript: try VoiceInputDocumentPipeline().process(raw, style: .natural),
      audioArtifact: VoiceInputHistoryAudioArtifact(
        url: audioURL,
        byteCount: 7,
        sha256: String(repeating: "a", count: 64)
      )
    )
  }
}
