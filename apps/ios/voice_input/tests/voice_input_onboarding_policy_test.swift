import Foundation
import XCTest

@testable import VoiceInputShared

final class VoiceInputOnboardingPolicyTest: XCTestCase {
  func testUndeterminedMicrophonePermissionIsRequestedExplicitly() {
    XCTAssertEqual(
      VoiceInputOnboardingPolicy().nextStep(
        microphone: .undetermined,
        keyboardHandoffObserved: false
      ),
      .requestMicrophone
    )
  }

  func testDeniedMicrophonePermissionOffersSettingsRecovery() {
    XCTAssertEqual(
      VoiceInputOnboardingPolicy().nextStep(
        microphone: .denied,
        keyboardHandoffObserved: false
      ),
      .openMicrophoneSettings
    )
  }

  func testAuthorizedMicrophoneAdvancesToKeyboardSetup() {
    XCTAssertEqual(
      VoiceInputOnboardingPolicy().nextStep(
        microphone: .authorized,
        keyboardHandoffObserved: false
      ),
      .enableKeyboard
    )
  }

  func testObservedKeyboardCompletesLocalOnboarding() {
    XCTAssertEqual(
      VoiceInputOnboardingPolicy().nextStep(
        microphone: .authorized,
        keyboardHandoffObserved: true
      ),
      .ready
    )
  }
}
