import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerApp

@MainActor
struct AppModelTests {
  /// A failed save must leave presentation and runtime configuration unchanged.
  @Test
  func failedSaveDoesNotPublishTheCandidateProfile() async throws {
    let model = AppModel(
      arguments: ["HardwareController", "--demo"],
      profileStore: FailingProfileStore()
    )
    model.start()
    let originalEnvelope = model.envelope

    model.setAction(.keyboardShortcut, for: .left)
    try await waitUntil {
      model.lastError != nil
    }

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
  func rapidBindingEditsRemainOrdered() async throws {
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
    try await waitUntil {
      let binding = model.binding(for: .left)
      return binding.action.shortcut == shortcut
        && binding.interactionMode == .toggle
    }

    #expect(
      model.binding(for: .left).action.kind
        == .keyboardShortcut
    )
    await model.stop()
  }

  /// Preserves keyboard-fallback edits through the presentation intent queue.
  @Test
  func keyboardFallbackEditReachesTheActiveBinding() async throws {
    let model = AppModel(
      arguments: ["HardwareController", "--demo"]
    )
    model.start()

    model.setActivationShortcut(
      .suggestedControlActivation,
      for: .center
    )
    try await waitUntil {
      model.binding(for: .center).activationShortcut
        == .suggestedControlActivation
    }

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

@MainActor
/// Waits for an asynchronously published presentation condition.
private func waitUntil(
  timeout: Duration = .seconds(1),
  _ condition: @escaping @MainActor () -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if condition() {
      return
    }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Timed out waiting for presentation state.")
}
