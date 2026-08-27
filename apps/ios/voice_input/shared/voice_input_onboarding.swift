public enum VoiceInputMicrophoneAuthorization: Equatable, Sendable {
  case undetermined
  case denied
  case authorized
}

public enum VoiceInputOnboardingStep: Equatable, Sendable {
  case requestMicrophone
  case openMicrophoneSettings
  case enableKeyboard
  case ready
}

public struct VoiceInputOnboardingPolicy: Equatable, Sendable {
  public init() {}

  public func nextStep(
    microphone: VoiceInputMicrophoneAuthorization,
    keyboardHandoffObserved: Bool
  ) -> VoiceInputOnboardingStep {
    switch microphone {
    case .undetermined:
      return .requestMicrophone
    case .denied:
      return .openMicrophoneSettings
    case .authorized:
      return keyboardHandoffObserved ? .ready : .enableKeyboard
    }
  }
}
