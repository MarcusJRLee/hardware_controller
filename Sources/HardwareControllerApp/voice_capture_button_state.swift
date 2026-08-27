import HardwareControllerCore
import HardwareControllerMac

/// Derives one menu action from the authoritative Voice-session phase.
struct VoiceCaptureButtonState: Equatable, Sendable {
  let title: String
  let systemImage: String
  let isEnabled: Bool
  let command: DictationCommand?

  init(
    title: String,
    systemImage: String,
    isEnabled: Bool,
    command: DictationCommand?
  ) {
    self.title = title
    self.systemImage = systemImage
    self.isEnabled = isEnabled
    self.command = command
  }

  init(
    phase: LocalAIDictationPhase,
    canBegin: Bool
  ) {
    switch phase {
    case .idle, .completed, .failed:
      self.init(
        title: "Record Voice",
        systemImage: "mic.fill",
        isEnabled: canBegin,
        command: .begin
      )
    case .preparing, .listening:
      self.init(
        title: "Stop Recording",
        systemImage: "stop.fill",
        isEnabled: true,
        command: .finish
      )
    case .finalizing, .refining, .validating, .delivering,
      .canceling:
      self.init(
        title: "Finishing Voice…",
        systemImage: "waveform",
        isEnabled: false,
        command: nil
      )
    }
  }
}
