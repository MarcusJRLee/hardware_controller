import AVFAudio
import Foundation
import XCTest

@testable import VoiceInput

final class VoiceInputLifecycleNotificationMapperTest: XCTestCase {
  private let mapper = VoiceInputLifecycleNotificationMapper()

  func testOnlyInterruptionBeginProducesAnInterruptionEvent() {
    XCTAssertEqual(
      mapper.audioInterruption(
        Notification(
          name: AVAudioSession.interruptionNotification,
          userInfo: [
            AVAudioSessionInterruptionTypeKey:
              AVAudioSession.InterruptionType.began.rawValue
          ]
        )
      ),
      .audioInterruptionBegan
    )
    XCTAssertNil(
      mapper.audioInterruption(
        Notification(
          name: AVAudioSession.interruptionNotification,
          userInfo: [
            AVAudioSessionInterruptionTypeKey:
              AVAudioSession.InterruptionType.ended.rawValue
          ]
        )
      )
    )
    XCTAssertNil(
      mapper.audioInterruption(
        Notification(name: AVAudioSession.interruptionNotification)
      )
    )
  }

  func testEveryKnownRouteReasonMapsToThePortableLifecycleBoundary() {
    let cases: [(AVAudioSession.RouteChangeReason, VoiceInputAudioRouteChange)] = [
      (.newDeviceAvailable, .newDeviceAvailable),
      (.oldDeviceUnavailable, .oldDeviceUnavailable),
      (.categoryChange, .categoryChange),
      (.override, .override),
      (.wakeFromSleep, .wakeFromSleep),
      (.noSuitableRouteForCategory, .noSuitableRoute),
      (.routeConfigurationChange, .configurationChange),
      (.unknown, .unknown),
    ]

    for (systemReason, expectedReason) in cases {
      XCTAssertEqual(
        mapper.audioRouteChange(
          Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [
              AVAudioSessionRouteChangeReasonKey: systemReason.rawValue
            ]
          )
        ),
        .audioRouteChanged(expectedReason)
      )
    }
    XCTAssertNil(
      mapper.audioRouteChange(
        Notification(name: AVAudioSession.routeChangeNotification)
      )
    )
  }

  func testEveryThermalStateMapsWithoutImportingProcessInfoIntoThePolicy() {
    let cases: [(ProcessInfo.ThermalState, VoiceInputThermalState)] = [
      (.nominal, .nominal),
      (.fair, .fair),
      (.serious, .serious),
      (.critical, .critical),
    ]

    for (systemState, expectedState) in cases {
      XCTAssertEqual(
        mapper.thermalState(systemState),
        .thermalStateChanged(expectedState)
      )
    }
  }
}
