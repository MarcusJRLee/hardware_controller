import VoiceInputShared

/// What the Dictate screen shows and what its one button does. Pure, so every
/// state the record button can reach is covered without a simulator.
struct VoiceInputDictationPresentation: Equatable, Sendable {
  enum Action: Equatable, Sendable {
    case start
    case stop
    case requestMicrophone
    case openSettings
    /// Visible but inert while capture cannot begin or is finishing.
    case unavailable
  }

  let title: String
  let detail: String
  let action: Action
  /// The only state painted in the accent color.
  let isActive: Bool
  /// Finished text to show above the button.
  let result: String?

  struct Inputs: Equatable, Sendable {
    var phase: VoiceInputSnapshot.Phase
    var text: String?
    var microphone: VoiceInputMicrophoneAuthorization
    var isPreparingModel: Bool
    var hasSpeechModel: Bool
    var errorMessage: String?
    var lifecycleMessage: String?
  }

  init(_ inputs: Inputs) {
    result = inputs.phase == .ready ? inputs.text.flatMap { $0.isEmpty ? nil : $0 } : nil
    isActive = inputs.phase == .recording
    switch inputs.phase {
    case .recording:
      (title, detail, action) = ("Listening", "Tap to finish.", .stop)
      return
    case .transcribing:
      (title, detail, action) = ("Transcribing", "On this iPhone.", .unavailable)
      return
    case .idle, .ready, .interrupted, .failed:
      break
    }
    switch inputs.microphone {
    case .undetermined:
      (title, detail, action) = (
        "Ready", "Tap to allow the microphone and start.", .requestMicrophone
      )
      return
    case .denied:
      (title, detail, action) = (
        "Microphone is off", "Allow it in Settings to dictate.", .openSettings
      )
      return
    case .authorized:
      break
    }
    if inputs.isPreparingModel {
      (title, detail, action) = ("Preparing speech model", "This takes a moment.", .unavailable)
      return
    }
    guard inputs.hasSpeechModel else {
      (title, detail, action) = (
        "No speech model", "Choose one in Settings → Speech model.", .unavailable
      )
      return
    }
    switch inputs.phase {
    case .ready:
      (title, detail) = ("Done", "Saved to History.")
    case .interrupted:
      (title, detail) = (
        "Stopped",
        inputs.lifecycleMessage ?? "Recording was interrupted. The audio is in History."
      )
    case .failed:
      (title, detail) = ("Didn't finish", inputs.errorMessage ?? "Try again.")
    case .idle, .recording, .transcribing:
      (title, detail) = ("Ready", inputs.errorMessage ?? "Tap to dictate.")
    }
    action = .start
  }
}
