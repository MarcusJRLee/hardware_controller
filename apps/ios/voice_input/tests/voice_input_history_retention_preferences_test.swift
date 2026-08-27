import Foundation
import HardwareControllerVoiceCore
import XCTest

@testable import VoiceInput

final class VoiceInputHistoryRetentionPreferencesTest: XCTestCase {
  @MainActor
  func testMissingPreferenceUsesIOSDefaultsAndRoundTripsValidatedSettings() throws {
    let fixture = try PreferencesFixture()
    addTeardownBlock { fixture.remove() }
    let store = VoiceInputHistoryRetentionPreferenceStore(
      defaults: fixture.defaults,
      key: fixture.key
    )
    let settings = VoiceHistoryRetentionSettings(
      maximumAgeDays: 30,
      maximumAudioBytes: 512 * 1_024 * 1_024,
      maximumArtifactCount: 500
    )

    XCTAssertEqual(try store.read(), .iOSDefault)
    try store.write(settings)

    XCTAssertEqual(try store.read(), settings)
  }

  @MainActor
  func testInvalidSettingsNeverReplaceTheStoredPreference() throws {
    let fixture = try PreferencesFixture()
    addTeardownBlock { fixture.remove() }
    let store = VoiceInputHistoryRetentionPreferenceStore(
      defaults: fixture.defaults,
      key: fixture.key
    )
    try store.write(.iOSDefault)

    XCTAssertThrowsError(
      try store.write(
        VoiceHistoryRetentionSettings(
          maximumAgeDays: -1,
          maximumAudioBytes: nil,
          maximumArtifactCount: nil
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? VoiceInputHistoryRetentionPreferenceError,
        .invalidSettings
      )
    }
    XCTAssertEqual(try store.read(), .iOSDefault)
  }

  @MainActor
  func testFutureSchemaIsPreservedWithoutOverwrite() throws {
    let fixture = try PreferencesFixture()
    addTeardownBlock { fixture.remove() }
    let future = Data(
      """
      {"schemaRevision":2,"settings":{"maximumAgeDays":90,"maximumAudioBytes":1073741824,"maximumArtifactCount":2000}}
      """.utf8
    )
    fixture.defaults.set(future, forKey: fixture.key)
    let store = VoiceInputHistoryRetentionPreferenceStore(
      defaults: fixture.defaults,
      key: fixture.key
    )

    XCTAssertThrowsError(try store.read()) { error in
      XCTAssertEqual(
        error as? VoiceInputHistoryRetentionPreferenceError,
        .unsupportedSchema
      )
    }
    XCTAssertEqual(fixture.defaults.data(forKey: fixture.key), future)
  }
}

private struct PreferencesFixture: @unchecked Sendable {
  let suiteName = "voice-input-retention-\(UUID().uuidString)"
  let defaults: UserDefaults
  let key = "retention"

  init() throws {
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  func remove() {
    defaults.removePersistentDomain(forName: suiteName)
  }
}
