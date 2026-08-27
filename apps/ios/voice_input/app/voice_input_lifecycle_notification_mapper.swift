import AVFAudio
import Foundation

struct VoiceInputLifecycleNotificationMapper: Equatable, Sendable {
  func audioInterruption(_ notification: Notification) -> VoiceInputLifecycleEvent? {
    guard
      let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: rawValue),
      type == .began
    else {
      return nil
    }
    return .audioInterruptionBegan
  }

  func audioRouteChange(_ notification: Notification) -> VoiceInputLifecycleEvent? {
    guard
      let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue)
    else {
      return nil
    }
    let mappedReason: VoiceInputAudioRouteChange =
      switch reason {
      case .newDeviceAvailable: .newDeviceAvailable
      case .oldDeviceUnavailable: .oldDeviceUnavailable
      case .categoryChange: .categoryChange
      case .override: .override
      case .wakeFromSleep: .wakeFromSleep
      case .noSuitableRouteForCategory: .noSuitableRoute
      case .routeConfigurationChange: .configurationChange
      case .unknown: .unknown
      @unknown default: .unknown
      }
    return .audioRouteChanged(mappedReason)
  }

  func thermalState(_ state: ProcessInfo.ThermalState) -> VoiceInputLifecycleEvent {
    let mappedState: VoiceInputThermalState =
      switch state {
      case .nominal: .nominal
      case .fair: .fair
      case .serious: .serious
      case .critical: .critical
      @unknown default: .critical
      }
    return .thermalStateChanged(mappedState)
  }
}
