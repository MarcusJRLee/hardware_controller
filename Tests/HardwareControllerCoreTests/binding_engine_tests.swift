import Foundation
import Testing

@testable import HardwareControllerCore

struct BindingEngineTests {
  private let deviceID = DeviceID(rawValue: "pedal-1")
  private let matchRule = DeviceMatchRule(modelID: .vecInfinity3)

  @Test
  func momentaryBeginsOnceAndEndsOnce() {
    var engine = BindingEngine()
    let binding = binding(.center)

    let firstPress = engine.handle(
      event(.center, .pressed, timestamp: 1),
      binding: binding
    )
    let repeatedPress = engine.handle(
      event(.center, .pressed, timestamp: 2),
      binding: binding
    )
    let release = engine.handle(
      event(.center, .released, timestamp: 3),
      binding: binding
    )
    let repeatedRelease = engine.handle(
      event(.center, .released, timestamp: 4),
      binding: binding
    )

    #expect(firstPress.map(\.phase) == [.begin])
    #expect(repeatedPress.isEmpty)
    #expect(release.map(\.phase) == [.end])
    #expect(repeatedRelease.isEmpty)
    #expect(!engine.isActive(deviceID: deviceID, controlID: .center))
  }

  @Test
  func toggleChangesOnlyOnPress() {
    let binding = Binding(
      controlID: .center,
      interactionMode: .toggle,
      action: .dictation()
    )
    var engine = BindingEngine()

    let begin = engine.handle(
      event(.center, .pressed, timestamp: 1),
      binding: binding
    )
    let firstRelease = engine.handle(
      event(.center, .released, timestamp: 2),
      binding: binding
    )
    let end = engine.handle(
      event(.center, .pressed, timestamp: 3),
      binding: binding
    )

    #expect(begin.map(\.phase) == [.begin])
    #expect(firstRelease.isEmpty)
    #expect(end.map(\.phase) == [.end])
  }

  @Test
  func shortcutPerformsOnceAndDoesNotBecomeActive() {
    let binding = Binding(
      controlID: .left,
      interactionMode: .momentary,
      action: .keyboardShortcut(
        KeyboardShortcut(keyCode: 15, modifiers: [.command])
      )
    )
    var engine = BindingEngine()

    let press = engine.handle(
      event(.left, .pressed, timestamp: 1),
      binding: binding
    )
    let release = engine.handle(
      event(.left, .released, timestamp: 2),
      binding: binding
    )

    #expect(press.map(\.phase) == [.perform])
    #expect(release.isEmpty)
    #expect(!engine.isActive(deviceID: deviceID, controlID: .left))
  }

  @Test
  func unavailableActionDoesNotBecomeActive() {
    var engine = BindingEngine()

    let invocations = engine.handle(
      event(.center, .pressed, timestamp: 1),
      binding: binding(.center),
      canExecute: { _ in false }
    )

    #expect(invocations.isEmpty)
    #expect(engine.isPressed(deviceID: deviceID, controlID: .center))
    #expect(!engine.isActive(deviceID: deviceID, controlID: .center))
  }

  /// Keeps a Control press observable while safely ignoring missing setup.
  @Test
  func missingBindingRemainsInert() {
    var engine = BindingEngine()

    let invocations = engine.handle(
      event(.center, .pressed, timestamp: 1),
      binding: nil
    )

    #expect(invocations.isEmpty)
    #expect(engine.isPressed(deviceID: deviceID, controlID: .center))
    #expect(!engine.isActive(deviceID: deviceID, controlID: .center))
  }

  @Test
  func failedBeginReleasesActionOwnership() throws {
    var engine = BindingEngine()
    let invocation = try #require(
      engine.handle(
        event(.center, .pressed, timestamp: 1),
        binding: binding(.center)
      ).first
    )

    engine.reconcileFailedBegin(invocation)

    #expect(!engine.isActive(deviceID: deviceID, controlID: .center))
  }

  @Test
  func asynchronousFailureReleasesMatchingActions() {
    var engine = BindingEngine()
    _ = engine.handle(
      event(.center, .pressed, timestamp: 1),
      binding: binding(.center)
    )

    engine.reconcileFailure(of: .dictation)

    #expect(!engine.isActive(deviceID: deviceID, controlID: .center))
  }

  @Test
  func dictationMovesActiveOwnershipBetweenControls() {
    let leftBinding = Binding(
      controlID: .left,
      interactionMode: .toggle,
      action: .dictation()
    )
    var engine = BindingEngine()
    _ = engine.handle(
      event(.left, .pressed, timestamp: 1),
      binding: leftBinding
    )
    _ = engine.handle(
      event(.left, .released, timestamp: 2),
      binding: leftBinding
    )
    let handoff = engine.handle(
      event(.center, .pressed, timestamp: 3),
      binding: binding(.center)
    )

    let cleanup = engine.cancel(
      deviceID: deviceID,
      timestampNanoseconds: 4
    )

    #expect(handoff.map(\.controlID) == [.left, .center])
    #expect(handoff.map(\.phase) == [.end, .begin])
    #expect(cleanup.map(\.controlID) == [.center])
    #expect(cleanup.map(\.phase) == [.end])
    #expect(!engine.isActive(deviceID: deviceID, controlID: .left))
    #expect(!engine.isActive(deviceID: deviceID, controlID: .center))
  }

  /// Hands microphone ownership between the distinct Dictation Actions.
  @Test
  func localAIDictationEndsLocalDictationBeforeBeginning() {
    let local = Binding(
      controlID: .left,
      interactionMode: .toggle,
      action: .dictation()
    )
    let localAI = Binding(
      controlID: .center,
      interactionMode: .momentary,
      action: .localAIDictation()
    )
    var engine = BindingEngine()
    _ = engine.handle(
      event(.left, .pressed, timestamp: 1),
      binding: local
    )
    _ = engine.handle(
      event(.left, .released, timestamp: 2),
      binding: local
    )

    let handoff = engine.handle(
      event(.center, .pressed, timestamp: 3),
      binding: localAI
    )

    #expect(handoff.map(\.action.kind) == [.dictation, .localAIDictation])
    #expect(handoff.map(\.phase) == [.end, .begin])
  }

  /// Keeps one momentary Action active until every input source releases it.
  @Test
  func momentaryTargetAggregatesPhysicalAndKeyboardOwnership() throws {
    var engine = BindingEngine()
    let targetID = BindingTargetID(
      configurationID: UUID(),
      controlID: .center
    )
    let physical = event(.center, .pressed, timestamp: 1)
    let keyboardDeviceID = DeviceID(rawValue: "keyboard-fallback")
    let keyboardPress = ControlEvent(
      deviceID: keyboardDeviceID,
      controlID: .center,
      phase: .pressed,
      timestampNanoseconds: 2
    )

    let begin = engine.handle(
      physical,
      targetID: targetID,
      binding: binding(.center)
    )
    let secondBegin = engine.handle(
      keyboardPress,
      targetID: targetID,
      binding: binding(.center)
    )
    let firstRelease = engine.handle(
      event(.center, .released, timestamp: 3),
      targetID: targetID,
      binding: binding(.center)
    )
    let end = engine.handle(
      ControlEvent(
        deviceID: keyboardDeviceID,
        controlID: .center,
        phase: .released,
        timestampNanoseconds: 4
      ),
      targetID: targetID,
      binding: binding(.center)
    )

    #expect(begin.map(\.phase) == [.begin])
    #expect(secondBegin.isEmpty)
    #expect(firstRelease.isEmpty)
    #expect(end.map(\.phase) == [.end])
    #expect(!engine.isActive(targetID: targetID))
  }

  /// Disconnecting one source preserves another source's momentary ownership.
  @Test
  func sourceCancellationPreservesSharedTargetOwnership() {
    var engine = BindingEngine()
    let targetID = BindingTargetID(
      configurationID: UUID(),
      controlID: .center
    )
    let keyboardDeviceID = DeviceID(rawValue: "keyboard-fallback")
    _ = engine.handle(
      event(.center, .pressed, timestamp: 1),
      targetID: targetID,
      binding: binding(.center)
    )
    _ = engine.handle(
      ControlEvent(
        deviceID: keyboardDeviceID,
        controlID: .center,
        phase: .pressed,
        timestampNanoseconds: 2
      ),
      targetID: targetID,
      binding: binding(.center)
    )

    let cancellation = engine.cancel(
      deviceID: deviceID,
      timestampNanoseconds: 3
    )

    #expect(cancellation.isEmpty)
    #expect(engine.isActive(targetID: targetID))
  }

  /// Lets either source advance one shared toggle lifecycle.
  @Test
  func toggleTargetChangesAcrossInputSources() {
    let toggleBinding = Binding(
      controlID: .center,
      interactionMode: .toggle,
      action: .dictation()
    )
    let targetID = BindingTargetID(
      configurationID: UUID(),
      controlID: .center
    )
    let keyboardDeviceID = DeviceID(rawValue: "keyboard-fallback")
    var engine = BindingEngine()

    let begin = engine.handle(
      ControlEvent(
        deviceID: keyboardDeviceID,
        controlID: .center,
        phase: .pressed,
        timestampNanoseconds: 1
      ),
      targetID: targetID,
      binding: toggleBinding
    )
    _ = engine.handle(
      ControlEvent(
        deviceID: keyboardDeviceID,
        controlID: .center,
        phase: .released,
        timestampNanoseconds: 2
      ),
      targetID: targetID,
      binding: toggleBinding
    )
    let end = engine.handle(
      event(.center, .pressed, timestamp: 3),
      targetID: targetID,
      binding: toggleBinding
    )

    #expect(begin.map(\.phase) == [.begin])
    #expect(end.map(\.phase) == [.end])
    #expect(!engine.isActive(targetID: targetID))
  }

  /// Returns one default Infinity Binding.
  private func binding(_ controlID: ControlID) -> Binding? {
    Profile.defaultProfile.binding(
      for: controlID,
      matching: matchRule
    )
  }

  /// Creates one deterministic Control event.
  private func event(
    _ controlID: ControlID,
    _ phase: ControlPhase,
    timestamp: UInt64
  ) -> ControlEvent {
    ControlEvent(
      deviceID: deviceID,
      controlID: controlID,
      phase: phase,
      timestampNanoseconds: timestamp
    )
  }
}
