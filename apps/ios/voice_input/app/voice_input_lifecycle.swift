import Foundation

enum VoiceInputCaptureInterruptionReason: String, Codable, Equatable, Sendable {
  case audioInterruption
  case audioRouteChange
  case mediaServicesUnavailable
  case backgroundOwnershipUnavailable
  case backgroundExecutionExpired
  case thermalPressure
  case processTermination
  case finalizationFailure
}

enum VoiceInputAudioRouteChange: CaseIterable, Equatable, Sendable {
  case newDeviceAvailable
  case oldDeviceUnavailable
  case categoryChange
  case override
  case wakeFromSleep
  case noSuitableRoute
  case configurationChange
  case unknown
}

enum VoiceInputThermalState: Equatable, Sendable {
  case nominal
  case fair
  case serious
  case critical
}

enum VoiceInputLifecycleEvent: Equatable, Sendable {
  case audioInterruptionBegan
  case audioRouteChanged(VoiceInputAudioRouteChange)
  case mediaServicesUnavailable
  case enteredBackground
  case lowPowerModeChanged(isEnabled: Bool)
  case thermalStateChanged(VoiceInputThermalState)
}

enum VoiceInputLifecycleAdvisory: Equatable, Sendable {
  case audioRouteChanged
  case backgroundRecording
  case lowPowerMode
  case thermalPressure
}

enum VoiceInputLifecycleDecision: Equatable, Sendable {
  case ignore
  case continueCapture(advisory: VoiceInputLifecycleAdvisory?)
  case interrupt(VoiceInputCaptureInterruptionReason)
}

struct VoiceInputLifecyclePolicy: Equatable, Sendable {
  func decision(
    for event: VoiceInputLifecycleEvent,
    captureOwned: Bool,
    liveActivityOwned: Bool = false
  ) -> VoiceInputLifecycleDecision {
    guard captureOwned else {
      return .ignore
    }
    switch event {
    case .audioInterruptionBegan:
      return .interrupt(.audioInterruption)
    case .audioRouteChanged(let reason):
      switch reason {
      case .categoryChange, .override:
        return .continueCapture(advisory: .audioRouteChanged)
      case .newDeviceAvailable, .oldDeviceUnavailable, .wakeFromSleep,
        .noSuitableRoute, .configurationChange, .unknown:
        return .interrupt(.audioRouteChange)
      }
    case .mediaServicesUnavailable:
      return .interrupt(.mediaServicesUnavailable)
    case .enteredBackground:
      return liveActivityOwned
        ? .continueCapture(advisory: .backgroundRecording)
        : .interrupt(.backgroundOwnershipUnavailable)
    case .lowPowerModeChanged(let isEnabled):
      return .continueCapture(advisory: isEnabled ? .lowPowerMode : nil)
    case .thermalStateChanged(let state):
      switch state {
      case .nominal, .fair:
        return .continueCapture(advisory: nil)
      case .serious:
        return .continueCapture(advisory: .thermalPressure)
      case .critical:
        return .interrupt(.thermalPressure)
      }
    }
  }
}
