import Foundation

/// Deterministically reduces Control transitions into Action lifecycle calls.
public struct BindingEngine: Sendable {
  private struct InputKey: Hashable, Sendable {
    let deviceID: DeviceID
    let controlID: ControlID
  }

  /// Keeps legacy direct callers isolated from persistent Profile identities.
  private enum TargetKey: Hashable, Sendable {
    case binding(BindingTargetID)
    case input(InputKey)
  }

  private struct ActiveAction: Sendable {
    let action: ActionConfiguration
    let interactionMode: InteractionMode
    let invocationKey: InputKey
    var owners: Set<InputKey>
  }

  private var pressedInputs: Set<InputKey> = []
  private var pressedTargets: [InputKey: TargetKey] = [:]
  private var activeActions: [TargetKey: ActiveAction] = [:]

  public init() {}

  /// Handles one transition against an optional persistent Binding target.
  public mutating func handle(
    _ event: ControlEvent,
    targetID: BindingTargetID? = nil,
    binding: Binding?,
    canExecute: (ActionConfiguration) -> Bool = { _ in true }
  ) -> [ActionInvocation] {
    let inputKey = InputKey(
      deviceID: event.deviceID,
      controlID: event.controlID
    )

    switch event.phase {
    case .pressed:
      guard pressedInputs.insert(inputKey).inserted else {
        return []
      }
      guard
        let binding,
        binding.action.kind != .noAction,
        canExecute(binding.action)
      else {
        return []
      }
      let targetKey = targetID.map(TargetKey.binding) ?? .input(inputKey)
      pressedTargets[inputKey] = targetKey
      return press(
        inputKey: inputKey,
        targetKey: targetKey,
        binding: binding,
        timestampNanoseconds: event.timestampNanoseconds
      )

    case .released:
      guard pressedInputs.remove(inputKey) != nil else {
        return []
      }
      guard
        let targetKey = pressedTargets.removeValue(forKey: inputKey),
        var active = activeActions[targetKey],
        active.interactionMode == .momentary
      else {
        return []
      }
      active.owners.remove(inputKey)
      guard active.owners.isEmpty else {
        activeActions[targetKey] = active
        return []
      }
      activeActions.removeValue(forKey: targetKey)
      return [
        invocation(
          key: active.invocationKey,
          action: active.action,
          phase: .end,
          timestampNanoseconds: event.timestampNanoseconds
        )
      ]
    }
  }

  /// Cancels only ownership originating from one input Device.
  public mutating func cancel(
    deviceID: DeviceID,
    timestampNanoseconds: UInt64
  ) -> [ActionInvocation] {
    let removedInputs = pressedInputs.filter {
      $0.deviceID == deviceID
    }
    pressedInputs.subtract(removedInputs)
    for inputKey in removedInputs {
      pressedTargets.removeValue(forKey: inputKey)
    }

    var invocations: [ActionInvocation] = []
    for targetKey in sortedActiveTargetKeys() {
      guard var active = activeActions[targetKey] else {
        continue
      }
      let ownedInputs = active.owners.filter {
        $0.deviceID == deviceID
      }
      guard !ownedInputs.isEmpty else {
        continue
      }
      active.owners.subtract(ownedInputs)
      guard active.owners.isEmpty else {
        activeActions[targetKey] = active
        continue
      }
      activeActions.removeValue(forKey: targetKey)
      invocations.append(
        invocation(
          key: active.invocationKey,
          action: active.action,
          phase: .end,
          timestampNanoseconds: timestampNanoseconds
        )
      )
    }
    return invocations
  }

  /// Cancels every active Action and clears all pressed input state.
  public mutating func cancelAll(
    timestampNanoseconds: UInt64
  ) -> [ActionInvocation] {
    pressedInputs.removeAll()
    pressedTargets.removeAll()
    let targetKeys = sortedActiveTargetKeys()

    return targetKeys.compactMap { targetKey in
      guard let active = activeActions.removeValue(forKey: targetKey) else {
        return nil
      }
      return invocation(
        key: active.invocationKey,
        action: active.action,
        phase: .end,
        timestampNanoseconds: timestampNanoseconds
      )
    }
  }

  /// Reports physical or synthetic input state independently from Action state.
  public func isPressed(
    deviceID: DeviceID,
    controlID: ControlID
  ) -> Bool {
    pressedInputs.contains(
      InputKey(deviceID: deviceID, controlID: controlID)
    )
  }

  /// Reports Action state for legacy input-scoped callers.
  public func isActive(
    deviceID: DeviceID,
    controlID: ControlID
  ) -> Bool {
    activeActions[
      .input(InputKey(deviceID: deviceID, controlID: controlID))
    ] != nil
  }

  /// Reports Action state for one persistent Profile Binding.
  public func isActive(targetID: BindingTargetID) -> Bool {
    activeActions[.binding(targetID)] != nil
  }

  /// Reports whether any logical Binding currently owns an Action.
  public var hasActiveActions: Bool {
    !activeActions.isEmpty
  }

  /// Removes ownership that was recorded before a begin invocation failed.
  public mutating func reconcileFailedBegin(
    _ invocation: ActionInvocation
  ) {
    guard invocation.phase == .begin else {
      return
    }
    let inputKey = InputKey(
      deviceID: invocation.deviceID,
      controlID: invocation.controlID
    )
    guard
      let targetKey = pressedTargets[inputKey],
      activeActions[targetKey]?.action == invocation.action
    else {
      return
    }
    activeActions.removeValue(forKey: targetKey)
  }

  /// Removes active ownership after an asynchronous Action failure.
  public mutating func reconcileFailure(
    of actionKind: ActionKind
  ) {
    activeActions = activeActions.filter {
      $0.value.action.kind != actionKind
    }
  }

  /// Applies one distinct press to a logical Binding target.
  private mutating func press(
    inputKey: InputKey,
    targetKey: TargetKey,
    binding: Binding,
    timestampNanoseconds: UInt64
  ) -> [ActionInvocation] {
    if binding.action.kind == .keyboardShortcut {
      return [
        invocation(
          key: inputKey,
          action: binding.action,
          phase: .perform,
          timestampNanoseconds: timestampNanoseconds
        )
      ]
    }

    var invocations =
      binding.action.kind.ownsDictationSession
      ? endOtherDictationActions(
        excluding: targetKey,
        timestampNanoseconds: timestampNanoseconds
      )
      : []

    switch binding.interactionMode {
    case .momentary:
      if var active = activeActions[targetKey] {
        active.owners.insert(inputKey)
        activeActions[targetKey] = active
        return invocations
      }

      activeActions[targetKey] = ActiveAction(
        action: binding.action,
        interactionMode: .momentary,
        invocationKey: inputKey,
        owners: [inputKey]
      )
      invocations.append(
        invocation(
          key: inputKey,
          action: binding.action,
          phase: .begin,
          timestampNanoseconds: timestampNanoseconds
        )
      )
      return invocations

    case .toggle:
      if let active = activeActions.removeValue(forKey: targetKey) {
        invocations.append(
          invocation(
            key: active.invocationKey,
            action: active.action,
            phase: .end,
            timestampNanoseconds: timestampNanoseconds
          )
        )
        return invocations
      }

      activeActions[targetKey] = ActiveAction(
        action: binding.action,
        interactionMode: .toggle,
        invocationKey: inputKey,
        owners: [inputKey]
      )
      invocations.append(
        invocation(
          key: inputKey,
          action: binding.action,
          phase: .begin,
          timestampNanoseconds: timestampNanoseconds
        )
      )
      return invocations
    }
  }

  /// Preserves the one-owned-Dictation invariant across all targets.
  private mutating func endOtherDictationActions(
    excluding targetKey: TargetKey,
    timestampNanoseconds: UInt64
  ) -> [ActionInvocation] {
    let targetKeys = sortedActiveTargetKeys().filter {
      $0 != targetKey
        && activeActions[$0]?.action.kind.ownsDictationSession == true
    }

    return targetKeys.compactMap { activeTargetKey in
      guard
        let active = activeActions.removeValue(forKey: activeTargetKey)
      else {
        return nil
      }
      return invocation(
        key: active.invocationKey,
        action: active.action,
        phase: .end,
        timestampNanoseconds: timestampNanoseconds
      )
    }
  }

  /// Returns deterministic target order through their invocation identities.
  private func sortedActiveTargetKeys() -> [TargetKey] {
    activeActions.keys.sorted {
      guard
        let lhs = activeActions[$0]?.invocationKey,
        let rhs = activeActions[$1]?.invocationKey
      else {
        return false
      }
      if lhs.deviceID.rawValue == rhs.deviceID.rawValue {
        return lhs.controlID.rawValue < rhs.controlID.rawValue
      }
      return lhs.deviceID.rawValue < rhs.deviceID.rawValue
    }
  }

  /// Creates one Action invocation with its originating input identity.
  private func invocation(
    key: InputKey,
    action: ActionConfiguration,
    phase: ActionInvocationPhase,
    timestampNanoseconds: UInt64
  ) -> ActionInvocation {
    ActionInvocation(
      deviceID: key.deviceID,
      controlID: key.controlID,
      action: action,
      phase: phase,
      inputTimestampNanoseconds: timestampNanoseconds
    )
  }
}
