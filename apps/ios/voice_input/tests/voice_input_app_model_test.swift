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

  @MainActor
  func testSelectedStylePersistsAndReachesInAppStop() async {
    let service = RecordingCaptureService()
    var persistedStyle: VoiceInputStyleKind?
    let model = VoiceInputAppModel(
      microphoneAuthorizationProvider: { .authorized },
      microphonePermissionRequester: { true },
      keyboardObservedAtReader: { nil },
      service: service,
      initialStyleKind: .natural,
      styleWriter: { persistedStyle = $0 }
    )

    model.selectStyle(.technical)
    await model.applyStop()
    let stoppedStyles = await service.stoppedStyles

    XCTAssertEqual(model.selectedStyleKind, .technical)
    XCTAssertEqual(persistedStyle, .technical)
    XCTAssertEqual(stoppedStyles, [.technical])
  }

  @MainActor
  func testStopFreezesStyleBeforeTheAsynchronousServiceCall() async {
    let service = RecordingCaptureService()
    let model = VoiceInputAppModel(
      microphoneAuthorizationProvider: { .authorized },
      microphonePermissionRequester: { true },
      keyboardObservedAtReader: { nil },
      service: service
    )

    model.selectStyle(.technical)
    model.stop()
    model.selectStyle(.formal)
    await service.waitForStop()
    let stoppedStyles = await service.stoppedStyles

    XCTAssertEqual(stoppedStyles, [.technical])
  }

  private enum TestError: Error {
    case unavailable
  }
}

private actor RecordingCaptureService: VoiceInputCapturing {
  private(set) var stoppedStyles: [VoiceInputStyleKind] = []
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []

  func snapshot() throws -> VoiceInputSnapshot { .idle(sequence: 0) }

  func start(sessionID _: UUID) async throws {}

  func stop(styleKind: VoiceInputStyleKind) async throws {
    stoppedStyles.append(styleKind)
    let waiters = stopWaiters
    stopWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func waitForStop() async {
    guard stoppedStyles.isEmpty else {
      return
    }
    await withCheckedContinuation { continuation in
      stopWaiters.append(continuation)
    }
  }

  func interrupt() async {}

  func processPendingCommand() async throws {}
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
