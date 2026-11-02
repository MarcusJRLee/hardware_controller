import VoiceInputShared
import XCTest

@testable import VoiceInput

final class VoiceInputDictationPresentationTest: XCTestCase {
  private let ready = VoiceInputDictationPresentation.Inputs(
    phase: .idle,
    text: nil,
    microphone: .authorized,
    isPreparingModel: false,
    hasSpeechModel: true,
    errorMessage: nil,
    lifecycleMessage: nil
  )

  private func present(
    _ change: (inout VoiceInputDictationPresentation.Inputs) -> Void = { _ in }
  ) -> VoiceInputDictationPresentation {
    var inputs = ready
    change(&inputs)
    return VoiceInputDictationPresentation(inputs)
  }

  func testEachStateMapsToOneTitleAndAction() {
    let cases:
      [(
        String, (inout VoiceInputDictationPresentation.Inputs) -> Void, String,
        VoiceInputDictationPresentation.Action
      )] = [
        ("idle", { _ in }, "Ready", .start),
        ("recording", { $0.phase = .recording }, "Listening", .stop),
        ("transcribing", { $0.phase = .transcribing }, "Transcribing", .unavailable),
        ("ready", { $0.phase = .ready }, "Done", .start),
        ("interrupted", { $0.phase = .interrupted }, "Stopped", .start),
        ("failed", { $0.phase = .failed }, "Didn't finish", .start),
        ("mic undetermined", { $0.microphone = .undetermined }, "Ready", .requestMicrophone),
        ("mic denied", { $0.microphone = .denied }, "Microphone is off", .openSettings),
        ("preparing", { $0.isPreparingModel = true }, "Preparing speech model", .unavailable),
        ("no model", { $0.hasSpeechModel = false }, "No speech model", .unavailable),
      ]
    for (name, change, title, action) in cases {
      let presentation = present(change)
      XCTAssertEqual(presentation.title, title, name)
      XCTAssertEqual(presentation.action, action, name)
    }
  }

  func testAnActiveRecordingOutranksSetupState() {
    let presentation = present {
      $0.phase = .recording
      $0.microphone = .denied
      $0.hasSpeechModel = false
    }
    XCTAssertEqual(presentation.action, .stop)
    XCTAssertTrue(presentation.isActive)
  }

  func testOnlyRecordingIsActive() {
    for phase in [VoiceInputSnapshot.Phase.idle, .transcribing, .ready, .failed] {
      XCTAssertFalse(present { $0.phase = phase }.isActive)
    }
  }

  func testResultShowsOnlyNonEmptyReadyText() {
    XCTAssertEqual(
      present {
        $0.phase = .ready
        $0.text = "Hello."
      }.result, "Hello.")
    XCTAssertNil(
      present {
        $0.phase = .ready
        $0.text = ""
      }.result)
    XCTAssertNil(
      present {
        $0.phase = .idle
        $0.text = "Stale."
      }.result)
  }

  func testMessagesExplainFailuresAndInterruptions() {
    XCTAssertEqual(
      present {
        $0.phase = .failed
        $0.errorMessage = "Recorder failed."
      }.detail,
      "Recorder failed."
    )
    XCTAssertEqual(
      present {
        $0.phase = .interrupted
        $0.lifecycleMessage = "A call stopped capture."
      }
      .detail,
      "A call stopped capture."
    )
  }
}
