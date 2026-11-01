import Foundation
import HardwareControllerCore
import HardwareControllerMac

/// Contains all non-presentation state published by the application runtime.
struct ApplicationSnapshot: Equatable, Sendable {
  var envelope: ProfileEnvelope
  var runtime = RuntimeSnapshot(
    devices: [],
    lastDispatchLatencyNanoseconds: nil,
    lastActionDispatchSucceeded: nil
  )
  var accessibilityTrusted: Bool
  var microphonePermission: PermissionStatus
  var speechRecognitionPermission: PermissionStatus
  var transcription: TranscriptionSnapshot
  var localAIDictation: LocalAIDictationSnapshot = .idle
  var localAIReadiness: LocalAIReadinessSnapshot = .checking
  var localAIProvider: LocalAIProviderKind = .appleOnDevice
  var localAIStyle: VoiceStyle = .natural
  var localAIProviderTest: LocalAIProviderTestState = .idle
  var transcriptionPrepared = false
  var transcriptionPreparationFailure: TranscriptionFailure?
  var launchAtLogin: Bool
  var hardwareInputFailure: HardwareInputStartFailure?
  var keyboardFallbackFailures: [KeyboardFallbackRegistrationFailure] = []
  var voiceShortcutFailure: VoiceShortcutRegistrationFailure?
  var lastError: String?
  var recoveryNotice: String?
}
