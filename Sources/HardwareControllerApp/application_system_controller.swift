import Foundation
import HardwareControllerCore
import HardwareControllerMac
import ServiceManagement

/// Describes the system state that controls Action availability.
struct ApplicationSystemState: Equatable, Sendable {
  let accessibilityTrusted: Bool
  let microphonePermission: PermissionStatus
  let speechRecognitionPermission: PermissionStatus
  let launchAtLogin: Bool
}

/// Identifies one permission request without leaking system frameworks.
enum ApplicationPermission: Sendable {
  case accessibility
  case microphone
  case speechRecognition
}

/// Isolates permission prompts and login-item registration on the main actor.
protocol ApplicationSystemControlling: Sendable {
  /// Returns authoritative permission and login-item state.
  @MainActor func currentState() -> ApplicationSystemState

  /// Requests one permission and returns refreshed system state.
  @MainActor func request(
    _ permission: ApplicationPermission
  ) async -> ApplicationSystemState

  /// Changes login-item registration and returns refreshed system state.
  @MainActor func setLaunchAtLogin(
    _ enabled: Bool
  ) throws -> ApplicationSystemState
}

/// Uses the actual macOS permission and login-item facilities.
@MainActor
final class SystemApplicationController:
  ApplicationSystemControlling
{
  private var stateOverride: ApplicationSystemState?

  /// Creates a live adapter, optionally with deterministic demo state.
  init(stateOverride: ApplicationSystemState? = nil) {
    self.stateOverride = stateOverride
  }

  /// Reads current permissions and login-item registration.
  func currentState() -> ApplicationSystemState {
    if let stateOverride {
      return stateOverride
    }
    return ApplicationSystemState(
      accessibilityTrusted: AccessibilityPermission.isTrusted,
      microphonePermission: MicrophonePermission.status,
      speechRecognitionPermission:
        LegacySpeechPermission.isRequired
        ? LegacySpeechPermission.status : .authorized,
      launchAtLogin: SMAppService.mainApp.status == .enabled
    )
  }

  /// Requests one permission and returns a complete refreshed state.
  func request(
    _ permission: ApplicationPermission
  ) async -> ApplicationSystemState {
    guard stateOverride == nil else {
      return currentState()
    }

    switch permission {
    case .accessibility:
      _ = AccessibilityPermission.request()
    case .microphone:
      _ = await MicrophonePermission.request()
    case .speechRecognition:
      _ = await LegacySpeechPermission.request()
    }
    return currentState()
  }

  /// Changes login-item registration and returns authoritative state.
  func setLaunchAtLogin(
    _ enabled: Bool
  ) throws -> ApplicationSystemState {
    if let current = stateOverride {
      let updated = ApplicationSystemState(
        accessibilityTrusted: current.accessibilityTrusted,
        microphonePermission: current.microphonePermission,
        speechRecognitionPermission:
          current.speechRecognitionPermission,
        launchAtLogin: enabled
      )
      stateOverride = updated
      return updated
    }

    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
    return currentState()
  }
}
