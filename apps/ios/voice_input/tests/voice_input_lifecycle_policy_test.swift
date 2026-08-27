import XCTest

@testable import VoiceInput

final class VoiceInputLifecyclePolicyTest: XCTestCase {
  private let policy = VoiceInputLifecyclePolicy()

  func testEventsCannotCreateLifecycleStateWithoutCaptureOwnership() {
    for event in VoiceInputLifecycleEvent.fixtureCases {
      XCTAssertEqual(
        policy.decision(for: event, captureOwned: false),
        .ignore
      )
    }
  }

  func testPrivacySensitiveAudioEventsInterruptWithoutAutomaticResume() {
    XCTAssertEqual(
      policy.decision(for: .audioInterruptionBegan, captureOwned: true),
      .interrupt(.audioInterruption)
    )
    XCTAssertEqual(
      policy.decision(for: .mediaServicesUnavailable, captureOwned: true),
      .interrupt(.mediaServicesUnavailable)
    )
    for reason in VoiceInputAudioRouteChange.allCases {
      let expected: VoiceInputLifecycleDecision =
        switch reason {
        case .categoryChange, .override:
          .continueCapture(advisory: .audioRouteChanged)
        case .newDeviceAvailable, .oldDeviceUnavailable, .wakeFromSleep,
          .noSuitableRoute, .configurationChange, .unknown:
          .interrupt(.audioRouteChange)
        }
      XCTAssertEqual(
        policy.decision(
          for: .audioRouteChanged(reason),
          captureOwned: true
        ),
        expected,
        "Unexpected route policy for \(reason)."
      )
    }
  }

  func testBackgroundCaptureRequiresVisibleLiveActivityOwnership() {
    XCTAssertEqual(
      policy.decision(
        for: .enteredBackground,
        captureOwned: true,
        liveActivityOwned: true
      ),
      .continueCapture(advisory: .backgroundRecording)
    )
    XCTAssertEqual(
      policy.decision(
        for: .enteredBackground,
        captureOwned: true,
        liveActivityOwned: false
      ),
      .interrupt(.backgroundOwnershipUnavailable)
    )
  }

  func testPowerAndThermalChangesAreExplicitAndFailClosedAtCriticalHeat() {
    XCTAssertEqual(
      policy.decision(
        for: .lowPowerModeChanged(isEnabled: true),
        captureOwned: true
      ),
      .continueCapture(advisory: .lowPowerMode)
    )
    XCTAssertEqual(
      policy.decision(
        for: .lowPowerModeChanged(isEnabled: false),
        captureOwned: true
      ),
      .continueCapture(advisory: nil)
    )
    XCTAssertEqual(
      policy.decision(
        for: .thermalStateChanged(.serious),
        captureOwned: true
      ),
      .continueCapture(advisory: .thermalPressure)
    )
    XCTAssertEqual(
      policy.decision(
        for: .thermalStateChanged(.critical),
        captureOwned: true
      ),
      .interrupt(.thermalPressure)
    )
    for state in [VoiceInputThermalState.nominal, .fair] {
      XCTAssertEqual(
        policy.decision(
          for: .thermalStateChanged(state),
          captureOwned: true
        ),
        .continueCapture(advisory: nil)
      )
    }
  }
}

extension VoiceInputLifecycleEvent {
  fileprivate static let fixtureCases: [Self] = [
    .audioInterruptionBegan,
    .audioRouteChanged(.oldDeviceUnavailable),
    .mediaServicesUnavailable,
    .enteredBackground,
    .lowPowerModeChanged(isEnabled: true),
    .thermalStateChanged(.serious),
  ]
}
