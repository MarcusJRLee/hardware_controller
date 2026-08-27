import AVFoundation
import Foundation
import Testing

@testable import HardwareControllerMac

struct VoiceAudioArtifactImporterTest {
  @Test
  func streamsAValidatedSourceIntoOneIndependentCAF() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "voice_artifact_import_\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let audioDirectory = root.appending(
      path: "audio",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: audioDirectory,
      withIntermediateDirectories: true
    )
    let sourceURL = root.appending(path: "source.wav")
    let sourceBuffer = try makeVoiceAudioFixture().makePCMBuffer()
    var source: AVAudioFile? = try AVAudioFile(
      forWriting: sourceURL,
      settings: sourceBuffer.format.settings
    )
    try source?.write(from: sourceBuffer)
    source = nil
    let sourceData = try Data(contentsOf: sourceURL)
    let sessionID = UUID()

    let artifactURL = try await VoiceAudioArtifactImporter().importAudio(
      from: sourceURL,
      sessionID: sessionID,
      audioDirectory: audioDirectory,
      limits: .macOSDefault
    )

    #expect(artifactURL.lastPathComponent == "\(sessionID).caf")
    #expect(try AVAudioFile(forReading: artifactURL).length == 1_600)
    #expect(try Data(contentsOf: sourceURL) == sourceData)
    #expect(
      !FileManager.default.fileExists(
        atPath: audioDirectory.appending(
          path: "\(sessionID).partial"
        ).path
      )
    )
  }
}
