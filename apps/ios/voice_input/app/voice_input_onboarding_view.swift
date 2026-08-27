import SwiftUI
import VoiceInputShared

struct VoiceInputOnboardingView: View {
  let step: VoiceInputOnboardingStep
  let microphoneAuthorization: VoiceInputMicrophoneAuthorization
  let keyboardHandoffObserved: Bool
  let errorMessage: String?
  let requestMicrophone: () -> Void
  let openSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Set up local voice").font(.title2.bold())
        Spacer()
        if step == .ready {
          Label("Ready", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("onboarding_ready")
        }
      }

      setupRow(
        symbol: "lock.shield",
        title: "Local processing",
        detail: "No account, cloud inference, analytics, or remote storage.",
        complete: true
      )

      setupRow(
        symbol: "mic",
        title: "Microphone",
        detail: microphoneDetail,
        complete: microphoneAuthorization == .authorized
      )

      if step == .requestMicrophone {
        Button("Allow microphone", action: requestMicrophone)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("request_microphone")
      } else if step == .openMicrophoneSettings {
        Button("Open microphone settings", action: openSettings)
          .buttonStyle(.bordered)
          .accessibilityIdentifier("open_microphone_settings")
      }

      setupRow(
        symbol: "keyboard",
        title: "Voice Keyboard",
        detail: keyboardDetail,
        complete: keyboardHandoffObserved
      )

      if let errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .accessibilityIdentifier("onboarding_error")
      }

      if microphoneAuthorization == .authorized && !keyboardHandoffObserved {
        Button("Open Settings", action: openSettings)
          .buttonStyle(.bordered)
          .accessibilityIdentifier("open_keyboard_settings")
        Text(
          "In Settings: General → Keyboard → Keyboards → Add New Keyboard → Voice Keyboard. Then enable Full Access for same-device handoff."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .padding(18)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityIdentifier("onboarding_card")
  }

  private var microphoneDetail: String {
    switch microphoneAuthorization {
    case .undetermined:
      return "Requested only when you choose Allow microphone."
    case .denied:
      return "Denied. Typing still works; enable access in Settings to record."
    case .authorized:
      return "Allowed for visibly owned, local capture only."
    }
  }

  private var keyboardDetail: String {
    if keyboardHandoffObserved {
      return "This keyboard completed a Full Access handoff check on this device."
    }
    return "Works as QWERTY without Full Access; voice handoff needs it."
  }

  private func setupRow(
    symbol: String,
    title: String,
    detail: String,
    complete: Bool
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: complete ? "checkmark.circle.fill" : symbol)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }
}
