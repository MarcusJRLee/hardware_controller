import AVFoundation
import AppKit
import Speech

public enum PermissionStatus: Equatable, Sendable {
  case notDetermined
  case restricted
  case denied
  case authorized
}

public enum MicrophonePermission {
  public static var status: PermissionStatus {
    map(AVCaptureDevice.authorizationStatus(for: .audio))
  }

  public static func request() async -> PermissionStatus {
    if status != .notDetermined {
      return status
    }
    _ = await AVCaptureDevice.requestAccess(for: .audio)
    return status
  }

  public static func openSystemSettings() {
    openPrivacySettings(anchor: "Privacy_Microphone")
  }

  static func map(
    _ status: AVAuthorizationStatus
  ) -> PermissionStatus {
    switch status {
    case .notDetermined:
      .notDetermined
    case .restricted:
      .restricted
    case .denied:
      .denied
    case .authorized:
      .authorized
    @unknown default:
      .denied
    }
  }
}

public enum LegacySpeechPermission {
  public static var isRequired: Bool {
    if #available(macOS 26, *) {
      false
    } else {
      true
    }
  }

  public static var status: PermissionStatus {
    map(SFSpeechRecognizer.authorizationStatus())
  }

  public static func request() async -> PermissionStatus {
    if !isRequired || status != .notDetermined {
      return isRequired ? status : .authorized
    }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { _ in
        continuation.resume(returning: status)
      }
    }
  }

  public static func openSystemSettings() {
    openPrivacySettings(anchor: "Privacy_SpeechRecognition")
  }

  static func map(
    _ status: SFSpeechRecognizerAuthorizationStatus
  ) -> PermissionStatus {
    switch status {
    case .notDetermined:
      .notDetermined
    case .restricted:
      .restricted
    case .denied:
      .denied
    case .authorized:
      .authorized
    @unknown default:
      .denied
    }
  }
}

private func openPrivacySettings(anchor: String) {
  guard
    let url = URL(
      string:
        "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
    )
  else {
    return
  }
  NSWorkspace.shared.open(url)
}
