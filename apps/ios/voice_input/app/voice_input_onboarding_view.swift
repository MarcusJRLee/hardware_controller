import SwiftUI
import VoiceInputShared

/// Setup status: the microphone and the optional Voice Keyboard.
struct VoiceInputSetupSection: View {
  let microphoneAuthorization: VoiceInputMicrophoneAuthorization
  let keyboardHandoffObserved: Bool
  let errorMessage: String?
  let requestMicrophone: () -> Void
  let openSettings: () -> Void

  var body: some View {
    Section {
      LabeledContent {
        switch microphoneAuthorization {
        case .undetermined:
          Button("Allow", action: requestMicrophone)
            .accessibilityIdentifier("request_microphone")
        case .denied:
          Button("Open Settings", action: openSettings)
            .accessibilityIdentifier("open_microphone_settings")
        case .authorized:
          Text("Allowed")
        }
      } label: {
        Label("Microphone", systemImage: "mic")
      }

      LabeledContent {
        if keyboardHandoffObserved {
          Text("Ready")
        } else {
          Button("Open Settings", action: openSettings)
            .accessibilityIdentifier("open_keyboard_settings")
        }
      } label: {
        Label("Voice Keyboard", systemImage: "keyboard")
      }

      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .accessibilityIdentifier("onboarding_error")
      }
    } header: {
      Text("Setup")
    } footer: {
      if !keyboardHandoffObserved {
        Text(
          "To dictate into any app: Settings → General → Keyboard → Keyboards → Add New Keyboard → Voice Keyboard, then turn on Allow Full Access."
        )
      }
    }
  }
}
