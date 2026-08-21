import Testing

@testable import HardwareControllerMac

struct SpeechAnalyzerRecognitionSessionTest {
  /// Treats result exhaustion before finalization as interruption.
  @Test
  func resultExhaustionWhileAcceptingInputIsUnexpected() {
    let lifecycle = SpeechAnalyzerRecognitionLifecycle()

    #expect(lifecycle.resultEndedUnexpectedly)
  }

  /// Allows result exhaustion after explicit finalization begins.
  @Test
  func resultExhaustionDuringFinalizationIsExpected() {
    var lifecycle = SpeechAnalyzerRecognitionLifecycle()

    let beganFinalization = lifecycle.beginFinalization()

    #expect(beganFinalization)
    #expect(!lifecycle.resultEndedUnexpectedly)
  }

  /// Distinguishes backend cancellation from app-owned cancellation.
  @Test
  func cancellationRequiresAnExplicitOwner() {
    var lifecycle = SpeechAnalyzerRecognitionLifecycle()

    #expect(
      lifecycle.cancellationWasUnexpected(
        taskIsCancelled: false
      )
    )
    #expect(
      !lifecycle.cancellationWasUnexpected(
        taskIsCancelled: true
      )
    )
    let stopped = lifecycle.stop()

    #expect(stopped)
    #expect(
      !lifecycle.cancellationWasUnexpected(
        taskIsCancelled: false
      )
    )
  }
}
