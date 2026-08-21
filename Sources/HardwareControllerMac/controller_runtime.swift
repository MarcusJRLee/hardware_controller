import Foundation
import HardwareControllerCore
import os

public struct ConnectedDeviceSnapshot: Equatable, Sendable {
  public let id: DeviceID
  public let name: String
  public let model: DeviceModelDescriptor
  public let matchRule: DeviceMatchRule
  public let pressedControls: Set<ControlID>
  public let activeControls: Set<ControlID>

  public init(
    id: DeviceID,
    name: String,
    model: DeviceModelDescriptor,
    matchRule: DeviceMatchRule,
    pressedControls: Set<ControlID>,
    activeControls: Set<ControlID>
  ) {
    self.id = id
    self.name = name
    self.model = model
    self.matchRule = matchRule
    self.pressedControls = pressedControls
    self.activeControls = activeControls
  }
}

public struct RuntimeSnapshot: Equatable, Sendable {
  public let devices: [ConnectedDeviceSnapshot]
  public let lastDispatchLatencyNanoseconds: UInt64?
  public let lastActionDispatchSucceeded: Bool?
  public let hasActiveActions: Bool

  public init(
    devices: [ConnectedDeviceSnapshot],
    lastDispatchLatencyNanoseconds: UInt64?,
    lastActionDispatchSucceeded: Bool? = nil,
    hasActiveActions: Bool = false
  ) {
    self.devices = devices
    self.lastDispatchLatencyNanoseconds =
      lastDispatchLatencyNanoseconds
    self.lastActionDispatchSucceeded =
      lastActionDispatchSucceeded
    self.hasActiveActions = hasActiveActions
  }
}

public struct ActionExecutionAvailability:
  Equatable,
  Sendable
{
  public var dictationAllowed: Bool
  public var localAIDictationAllowed: Bool
  public var keyboardShortcutsAllowed: Bool

  public init(
    dictationAllowed: Bool,
    localAIDictationAllowed: Bool = false,
    keyboardShortcutsAllowed: Bool
  ) {
    self.dictationAllowed = dictationAllowed
    self.localAIDictationAllowed = localAIDictationAllowed
    self.keyboardShortcutsAllowed =
      keyboardShortcutsAllowed
  }

  public static let unavailable =
    ActionExecutionAvailability(
      dictationAllowed: false,
      localAIDictationAllowed: false,
      keyboardShortcutsAllowed: false
    )

  public func allows(
    _ action: ActionConfiguration
  ) -> Bool {
    switch action.kind {
    case .noAction:
      true
    case .dictation:
      dictationAllowed
    case .localAIDictation:
      localAIDictationAllowed
    case .keyboardShortcut:
      keyboardShortcutsAllowed
    }
  }
}

/// Owns all mutable input and action state on one serial hot-path queue.
public final class ControllerRuntime<Executor: ActionExecuting>:
  @unchecked Sendable
{
  public let queue: DispatchQueue

  private let executor: Executor
  private let onSnapshot: @Sendable (RuntimeSnapshot) -> Void
  private let signposter = OSSignposter(
    subsystem: ApplicationIdentity.bundleIdentifier,
    category: "input"
  )

  private var engine = BindingEngine()
  private var profileResolver: ProfileBindingResolver
  private var connectedDevices: [DeviceID: HardwareDeviceConnection] = [:]
  private var pressedControls: [DeviceID: Set<ControlID>] = [:]
  private var actionExecutionAvailability =
    ActionExecutionAvailability.unavailable
  private var lastDispatchLatencyNanoseconds: UInt64?
  private var lastActionDispatchSucceeded: Bool?

  public init(
    queue: DispatchQueue,
    profile: Profile,
    executor: Executor,
    onSnapshot: @escaping @Sendable (RuntimeSnapshot) -> Void
  ) {
    self.queue = queue
    profileResolver = ProfileBindingResolver(profile: profile)
    self.executor = executor
    self.onSnapshot = onSnapshot
  }

  public func setActionExecutionAllowed(_ allowed: Bool) {
    setActionExecutionAvailability(
      ActionExecutionAvailability(
        dictationAllowed: allowed,
        localAIDictationAllowed: allowed,
        keyboardShortcutsAllowed: allowed
      )
    )
  }

  public func setActionExecutionAvailability(
    _ availability: ActionExecutionAvailability
  ) {
    queue.async { [self] in
      if actionExecutionAvailability != availability {
        execute(
          engine.cancelAll(
            timestampNanoseconds: MonotonicClock.nowNanoseconds()
          )
        )
      }
      actionExecutionAvailability = availability
      publishSnapshot()
    }
  }

  public func setProfile(_ newProfile: Profile) async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        execute(
          engine.cancelAll(
            timestampNanoseconds: MonotonicClock.nowNanoseconds()
          )
        )
        profileResolver = ProfileBindingResolver(profile: newProfile)
        publishSnapshot()
        continuation.resume()
      }
    }
  }

  public func connect(_ connection: HardwareDeviceConnection) {
    queue.async { [self] in
      connectedDevices[connection.id] = connection
      pressedControls[connection.id] = []
      publishSnapshot()
    }
  }

  public func disconnect(deviceID: DeviceID) {
    queue.async { [self] in
      execute(
        engine.cancel(
          deviceID: deviceID,
          timestampNanoseconds: MonotonicClock.nowNanoseconds()
        )
      )
      connectedDevices.removeValue(forKey: deviceID)
      pressedControls.removeValue(forKey: deviceID)
      publishSnapshot()
    }
  }

  public func handle(_ event: ControlEvent) {
    queue.async { [self] in
      if event.phase == .pressed {
        pressedControls[event.deviceID, default: []]
          .insert(event.controlID)
      } else {
        pressedControls[event.deviceID, default: []]
          .remove(event.controlID)
      }

      let resolvedBinding = connectedDevices[event.deviceID].flatMap {
        connection in
        profileResolver.resolvedBinding(
          for: event.controlID,
          matching: connection.matchRule
        )
      }
      process(
        event,
        targetID: resolvedBinding?.targetID,
        binding: resolvedBinding?.binding
      )
    }
  }

  /// Handles one exact keyboard fallback without requiring a connected Device.
  public func handleKeyboardFallback(
    _ registration: KeyboardFallbackRegistration,
    phase: ControlPhase,
    timestampNanoseconds: UInt64
  ) {
    queue.async { [self] in
      let event = ControlEvent(
        deviceID: registration.sourceDeviceID,
        controlID: registration.targetID.controlID,
        phase: phase,
        timestampNanoseconds: timestampNanoseconds
      )
      process(
        event,
        targetID: registration.targetID,
        binding: profileResolver.binding(for: registration.targetID)
      )
    }
  }

  /// Dispatches one already-resolved input transition on the hot-path queue.
  private func process(
    _ event: ControlEvent,
    targetID: BindingTargetID?,
    binding: Binding?
  ) {
    let signpostID = signposter.makeSignpostID()
    let interval = signposter.beginInterval(
      "Input to action",
      id: signpostID
    )

    let invocations = engine.handle(
      event,
      targetID: targetID,
      binding: binding,
      canExecute: { [actionExecutionAvailability] action in
        actionExecutionAvailability.allows(action)
      }
    )

    if !invocations.isEmpty {
      let dispatchTime = MonotonicClock.nowNanoseconds()
      lastDispatchLatencyNanoseconds =
        dispatchTime >= event.timestampNanoseconds
        ? dispatchTime - event.timestampNanoseconds
        : 0
      execute(invocations)
    }

    signposter.endInterval(
      "Input to action",
      interval
    )
    publishSnapshot()
  }

  /// Reconciles an action that failed after dispatch returned.
  public func actionDidFail(_ actionKind: ActionKind) {
    queue.async { [self] in
      engine.reconcileFailure(of: actionKind)
      publishSnapshot()
    }
  }

  /// Ends active Actions and forgets Devices without shutting down executors.
  public func suspend() {
    queue.sync { [self] in
      execute(
        engine.cancelAll(
          timestampNanoseconds: MonotonicClock.nowNanoseconds()
        )
      )
      connectedDevices.removeAll()
      pressedControls.removeAll()
      publishSnapshot()
    }
  }

  public func shutdown() {
    queue.sync { [self] in
      execute(
        engine.cancelAll(
          timestampNanoseconds: MonotonicClock.nowNanoseconds()
        )
      )
      executor.shutdown()
      connectedDevices.removeAll()
      pressedControls.removeAll()
      publishSnapshot()
    }
  }

  public func flush() {
    queue.sync {}
  }

  private func execute(_ invocations: [ActionInvocation]) {
    guard !invocations.isEmpty else {
      return
    }

    var succeeded = true
    for invocation in invocations {
      if !executor.execute(invocation) {
        engine.reconcileFailedBegin(invocation)
        succeeded = false
      }
    }
    lastActionDispatchSucceeded = succeeded
  }

  private func publishSnapshot() {
    let devices = connectedDevices.map { deviceID, connection in
      ConnectedDeviceSnapshot(
        id: deviceID,
        name: connection.name,
        model: connection.model,
        matchRule: connection.matchRule,
        pressedControls: pressedControls[deviceID] ?? [],
        activeControls: Set(
          connection.model.controls.map { $0.id }.filter {
            guard
              let targetID = profileResolver.resolvedBinding(
                for: $0,
                matching: connection.matchRule
              )?.targetID
            else {
              return false
            }
            return engine.isActive(targetID: targetID)
          }
        )
      )
    }
    .sorted { $0.id.rawValue < $1.id.rawValue }

    onSnapshot(
      RuntimeSnapshot(
        devices: devices,
        lastDispatchLatencyNanoseconds:
          lastDispatchLatencyNanoseconds,
        lastActionDispatchSucceeded:
          lastActionDispatchSucceeded,
        hasActiveActions: engine.hasActiveActions
      )
    )
  }
}
