import Foundation
import XCTest

@testable import VoiceInputShared

final class VoiceInputStylePreferenceTest: XCTestCase {
  @MainActor
  func testPreferencePersistsOnlyAValidatedCanonicalIdentifier() throws {
    let suiteName = "voice_input_style_test_\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preference = VoiceInputStylePreferenceStore(
      userDefaults: defaults,
      key: "style"
    )

    XCTAssertEqual(preference.read(), .natural)
    preference.write(.formal)
    XCTAssertEqual(preference.read(), .formal)

    defaults.set("unknown", forKey: "style")
    XCTAssertEqual(preference.read(), .natural)
  }
}
