import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerApp

@MainActor
struct AppModelTests {
  /// A failed save must leave presentation and runtime configuration unchanged.
  @Test
  func failedSaveDoesNotPublishTheCandidateProfile() async {
    let model = AppModel(
      arguments: ["HardwareController", "--demo"],
      profileStore: FailingProfileStore()
    )
    model.start()
    let originalEnvelope = model.envelope

    model.setAction(.keyboardShortcut, for: .left)
    await model.waitForPendingIntents()

    #expect(model.envelope == originalEnvelope)
    #expect(model.binding(for: .left).action == .noAction)
    #expect(model.lastError != nil)
    await model.stop()
  }

  /// Stops safely when termination races the asynchronous runtime start.
  @Test
  func immediateStopJoinsRuntimeStart() async throws {
    let model = AppModel(
      arguments: ["HardwareController", "--demo"]
    )

    model.start()
    await model.stop()
    try await Task.sleep(for: .milliseconds(10))

    #expect(!model.isConnected)
    #expect(!model.isAnyActionActive)
  }

  /// Preserves rapid UI mutation order before commands enter the runtime actor.
  @Test
  func rapidBindingEditsRemainOrdered() async {
    let model = AppModel(
      arguments: ["HardwareController", "--demo"]
    )
    let shortcut = KeyboardShortcut(
      keyCode: 49,
      modifiers: [.command, .shift]
    )
    model.start()

    model.setAction(.keyboardShortcut, for: .left)
    model.setInteractionMode(.toggle, for: .left)
    model.setShortcut(shortcut, for: .left)
    await model.waitForPendingIntents()

    #expect(
      model.binding(for: .left)
        == Binding(
          controlID: .left,
          interactionMode: .toggle,
          action: .keyboardShortcut(shortcut)
        )
    )
    await model.stop()
  }

  /// Preserves keyboard-fallback edits through the presentation intent queue.
  @Test
  func keyboardFallbackEditReachesTheActiveBinding() async {
    let model = AppModel(
      arguments: ["HardwareController", "--demo"]
    )
    model.start()

    model.setActivationShortcut(
      .suggestedControlActivation,
      for: .center
    )
    await model.waitForPendingIntents()

    #expect(
      model.binding(for: .center).activationShortcut
        == .suggestedControlActivation
    )
    await model.stop()
  }

  /// Ignores late UI intents after process ownership has ended.
  @Test
  func stoppedPresentationCannotMutateRuntimeState() async {
    let model = AppModel(
      arguments: ["HardwareController", "--demo"]
    )
    model.start()
    await model.stop()
    let envelope = model.envelope

    model.setAction(.keyboardShortcut, for: .left)
    try? await Task.sleep(for: .milliseconds(10))

    #expect(model.envelope == envelope)
  }
}

private struct FailingProfileStore: ProfilePersisting {
  /// Returns a valid initial Profile.
  func load() -> ProfileLoadResult {
    ProfileLoadResult(
      envelope: .defaultEnvelope(),
      issue: nil
    )
  }

  /// Simulates an atomic persistence failure.
  func save(_ envelope: ProfileEnvelope) throws {
    throw FailingProfileStoreError.couldNotWrite
  }
}

private enum FailingProfileStoreError: Error {
  case couldNotWrite
}
