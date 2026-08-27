import AppIntents
import Foundation
import VoiceInputShared

struct VoiceInputStartIntent: AudioRecordingIntent {
  static let title: LocalizedStringResource = "Start local voice capture"
  static let description = IntentDescription(
    "Opens Voice Input and starts an app-owned local recording."
  )
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    _ = try VoiceInputSystemCaptureCommandHandler().setRecording(
      true,
      store: VoiceInputKeychainStore()
    )
    return .result()
  }
}

struct VoiceInputStopIntent: AudioRecordingIntent, LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop local voice capture"
  static let description = IntentDescription(
    "Stops the exact active Voice Input recording and finalizes it locally."
  )
  static let openAppWhenRun = false

  func perform() async throws -> some IntentResult {
    _ = try VoiceInputSystemCaptureCommandHandler().setRecording(
      false,
      store: VoiceInputKeychainStore()
    )
    return .result()
  }
}

struct VoiceInputSetCaptureIntent: SetValueIntent, AudioRecordingIntent {
  static let title: LocalizedStringResource = "Local voice capture"
  static let description = IntentDescription(
    "Starts or stops app-owned local Voice Input capture."
  )
  static let openAppWhenRun = true

  @Parameter(title: "Recording")
  var value: Bool

  func perform() async throws -> some IntentResult {
    _ = try VoiceInputSystemCaptureCommandHandler().setRecording(
      value,
      store: VoiceInputKeychainStore()
    )
    return .result()
  }
}
