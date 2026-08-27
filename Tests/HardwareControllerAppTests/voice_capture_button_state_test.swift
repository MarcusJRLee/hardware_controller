import HardwareControllerCore
import HardwareControllerMac
import Testing

@testable import HardwareControllerApp

struct VoiceCaptureButtonStateTest {
  @Test
  func idleCompletedAndFailedStartOnlyWhenLocalAIIsAvailable() {
    for phase in [
      LocalAIDictationPhase.idle,
      .completed,
      .failed,
    ] {
      #expect(
        VoiceCaptureButtonState(
          phase: phase,
          canBegin: true
        )
          == VoiceCaptureButtonState(
            title: "Record Voice",
            systemImage: "mic.fill",
            isEnabled: true,
            command: .begin
          )
      )
      #expect(
        VoiceCaptureButtonState(
          phase: phase,
          canBegin: false
        ).isEnabled == false
      )
    }
  }

  @Test
  func preparingAndListeningAlwaysOfferToStopTheOwnedCapture() {
    for phase in [
      LocalAIDictationPhase.preparing,
      .listening,
    ] {
      #expect(
        VoiceCaptureButtonState(
          phase: phase,
          canBegin: false
        )
          == VoiceCaptureButtonState(
            title: "Stop Recording",
            systemImage: "stop.fill",
            isEnabled: true,
            command: .finish
          )
      )
    }
  }

  @Test
  func postCaptureWorkCannotStartOrFinishAnotherSession() {
    for phase in [
      LocalAIDictationPhase.finalizing,
      .refining,
      .validating,
      .delivering,
      .canceling,
    ] {
      #expect(
        VoiceCaptureButtonState(
          phase: phase,
          canBegin: true
        )
          == VoiceCaptureButtonState(
            title: "Finishing Voice…",
            systemImage: "waveform",
            isEnabled: false,
            command: nil
          )
      )
    }
  }
}
