import AVFoundation
import Speech
import Testing

@testable import HardwareControllerMac

struct TranscriptionPermissionTests {
  @Test(
    arguments: [
      (AVAuthorizationStatus.notDetermined, PermissionStatus.notDetermined),
      (AVAuthorizationStatus.restricted, PermissionStatus.restricted),
      (AVAuthorizationStatus.denied, PermissionStatus.denied),
      (AVAuthorizationStatus.authorized, PermissionStatus.authorized),
    ]
  )
  func mapsMicrophoneAuthorization(
    source: AVAuthorizationStatus,
    expected: PermissionStatus
  ) {
    #expect(MicrophonePermission.map(source) == expected)
  }

  @Test(
    arguments: [
      (
        SFSpeechRecognizerAuthorizationStatus.notDetermined,
        PermissionStatus.notDetermined
      ),
      (
        SFSpeechRecognizerAuthorizationStatus.restricted,
        PermissionStatus.restricted
      ),
      (
        SFSpeechRecognizerAuthorizationStatus.denied,
        PermissionStatus.denied
      ),
      (
        SFSpeechRecognizerAuthorizationStatus.authorized,
        PermissionStatus.authorized
      ),
    ]
  )
  func mapsLegacySpeechAuthorization(
    source: SFSpeechRecognizerAuthorizationStatus,
    expected: PermissionStatus
  ) {
    #expect(LegacySpeechPermission.map(source) == expected)
  }
}
