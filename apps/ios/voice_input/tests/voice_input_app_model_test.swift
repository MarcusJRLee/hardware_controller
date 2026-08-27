import Foundation
import VoiceInputShared
import XCTest

@testable import VoiceInput

final class VoiceInputAppModelTest: XCTestCase {
  @MainActor
  func testRefreshAdvancesToReadyAfterKeyboardObservation() {
    let model = VoiceInputAppModel(
      microphoneAuthorizationProvider: { .authorized },
      microphonePermissionRequester: { true },
      keyboardObservedAtReader: { Date(timeIntervalSince1970: 42) }
    )

    model.refreshOnboarding()

    XCTAssertEqual(model.microphoneAuthorization, .authorized)
    XCTAssertTrue(model.keyboardHandoffObserved)
    XCTAssertEqual(model.onboardingStep, .ready)
    XCTAssertNil(model.onboardingErrorMessage)
  }

  @MainActor
  func testRefreshSurfacesKeyboardHandoffFailure() {
    let model = VoiceInputAppModel(
      microphoneAuthorizationProvider: { .authorized },
      microphonePermissionRequester: { true },
      keyboardObservedAtReader: { throw TestError.unavailable }
    )

    model.refreshOnboarding()

    XCTAssertFalse(model.keyboardHandoffObserved)
    XCTAssertNotNil(model.onboardingErrorMessage)
  }

  @MainActor
  func testExplicitMicrophoneRequestUpdatesAuthorization() async {
    let model = VoiceInputAppModel(
      microphoneAuthorizationProvider: { .undetermined },
      microphonePermissionRequester: { true },
      keyboardObservedAtReader: { nil }
    )

    await model.applyMicrophoneRequest()

    XCTAssertEqual(model.microphoneAuthorization, .authorized)
  }

  @MainActor
  func testRefreshSurfacesCaptureStateReadFailure() async {
    let service = VoiceInputCaptureService(
      store: FailingSnapshotStore(),
      captureURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).caf")
    )
    let model = VoiceInputAppModel(
      microphoneAuthorizationProvider: { .authorized },
      microphonePermissionRequester: { true },
      keyboardObservedAtReader: { nil },
      service: service
    )

    await model.refresh()

    XCTAssertNotNil(model.snapshotErrorMessage)
  }

  private enum TestError: Error {
    case unavailable
  }
}

private struct FailingSnapshotStore: VoiceInputStateStoring {
  func readSnapshot() throws -> VoiceInputSnapshot {
    throw VoiceInputStoreError.invalidSnapshot
  }

  func writeSnapshot(_: VoiceInputSnapshot) throws {}

  func readCommand() throws -> VoiceInputCommand? { nil }

  func writeCommand(_: VoiceInputCommand) throws {}

  func consumeCommand() throws -> VoiceInputCommand? { nil }
}
