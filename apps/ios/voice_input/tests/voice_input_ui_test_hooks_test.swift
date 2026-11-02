import Foundation
import XCTest

@testable import VoiceInput

final class VoiceInputUITestHooksTest: XCTestCase {
  private let key = VoiceInputUITestHooks.audioFixtureEnvironmentKey

  func testResetNeedsTheExactArgument() {
    XCTAssertTrue(
      VoiceInputUITestHooks.shouldReset(arguments: ["app", "-voice_input_reset_state"]))
    XCTAssertFalse(VoiceInputUITestHooks.shouldReset(arguments: ["app", "-voice_input_reset"]))
  }

  func testFixtureNeedsAnExistingAbsolutePath() {
    let exists: (String) -> Bool = { $0 == "/fixtures/jfk.wav" }
    XCTAssertEqual(
      VoiceInputUITestHooks.audioFixtureURL(
        environment: [key: "/fixtures/jfk.wav"],
        fileExists: exists
      ),
      URL(fileURLWithPath: "/fixtures/jfk.wav")
    )
    for environment in [[:], [key: "jfk.wav"], [key: "/fixtures/missing.wav"]] {
      XCTAssertNil(
        VoiceInputUITestHooks.audioFixtureURL(environment: environment, fileExists: exists)
      )
    }
  }

  func testFixtureRecorderPlacesTheClipAtTheCaptureURL() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = root.appendingPathComponent("clip.wav")
    try Data("audio".utf8).write(to: fixture)
    let capture = root.appendingPathComponent("session.partial")

    let recorder = try VoiceInputFixtureAudioRecorderFactory(fixtureURL: fixture)
      .makeRecorder(at: capture)

    XCTAssertTrue(recorder.record())
    XCTAssertEqual(try Data(contentsOf: capture), Data("audio".utf8))
  }
}
