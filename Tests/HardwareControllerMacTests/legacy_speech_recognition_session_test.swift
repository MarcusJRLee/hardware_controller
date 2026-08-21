import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct LegacySpeechRecognitionSessionTest {
  /// Accepts a final result only after the app requests finalization.
  @Test
  func finalResultAfterFinalizationIsExpected() {
    var lifecycle = LegacyRecognitionLifecycle()

    let beganFinalization = lifecycle.beginFinalization()
    let expectedFinalResult = lifecycle.receiveFinalResult()

    #expect(beganFinalization)
    #expect(expectedFinalResult)
    #expect(lifecycle.isStopped)
  }

  /// Classifies an early final result as interrupted recognition.
  @Test
  func finalResultBeforeFinalizationIsInterrupted() {
    var lifecycle = LegacyRecognitionLifecycle()

    let expectedFinalResult = lifecycle.receiveFinalResult()

    #expect(!expectedFinalResult)
    #expect(lifecycle.isStopped)
  }

  /// Makes cancellation idempotent and prevents later finalization.
  @Test
  func cancellationStopsTheLifecycleOnce() {
    var lifecycle = LegacyRecognitionLifecycle()

    #expect(lifecycle.acceptsInput)
    let firstStop = lifecycle.stop()
    let secondStop = lifecycle.stop()
    let beganFinalization = lifecycle.beginFinalization()

    #expect(firstStop)
    #expect(!secondStop)
    #expect(!beganFinalization)
    #expect(!lifecycle.acceptsInput)
  }

  /// Requires permission, availability, and an on-device model.
  @Test
  func readinessFailsClosed() {
    #expect(throws: SpeechRecognitionBackendError.unavailable) {
      try LegacyOnDeviceSpeechRecognitionSession
        .validateReadiness(
          permission: .denied,
          recognizerAvailable: true,
          supportsOnDeviceRecognition: true
        )
    }
    #expect(throws: SpeechRecognitionBackendError.unavailable) {
      try LegacyOnDeviceSpeechRecognitionSession
        .validateReadiness(
          permission: .authorized,
          recognizerAvailable: false,
          supportsOnDeviceRecognition: true
        )
    }
    #expect(
      throws: SpeechRecognitionBackendError.modelUnavailable
    ) {
      try LegacyOnDeviceSpeechRecognitionSession
        .validateReadiness(
          permission: .authorized,
          recognizerAvailable: true,
          supportsOnDeviceRecognition: false
        )
    }
    #expect(throws: Never.self) {
      try LegacyOnDeviceSpeechRecognitionSession
        .validateReadiness(
          permission: .authorized,
          recognizerAvailable: true,
          supportsOnDeviceRecognition: true
        )
    }
  }
}
