import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct ControllerRuntimeTest {
  @Test
  func deniedPermissionStillPublishesPhysicalState() {
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = makeRuntime(
      executor: executor,
      snapshots: snapshots
    )
    let deviceID = DeviceID(rawValue: "pedal")

    runtime.connect(connection(deviceID))
    runtime.setActionExecutionAllowed(false)
    runtime.handle(
      event(deviceID: deviceID, phase: .pressed, timestamp: 1)
    )
    runtime.flush()

    #expect(executor.invocations.isEmpty)
    #expect(
      snapshots.latest?.devices.first?.pressedControls == [.center]
    )
    #expect(
      snapshots.latest?.devices.first?.activeControls.isEmpty == true
    )
  }

  @Test
  func actionTypesUseIndependentAvailability() throws {
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    var profile = Profile.defaultProfile
    let configuration = try #require(
      profile.configuration(
        matching: DeviceMatchRule(modelID: .vecInfinity3)
      )
    )
    try profile.setBinding(
      Binding(
        controlID: .left,
        interactionMode: .momentary,
        action: .keyboardShortcut(
          KeyboardShortcut(
            keyCode: 15,
            modifiers: [.command]
          )
        )
      ),
      configurationID: configuration.id
    )
    try profile.setBinding(
      Binding(
        controlID: .right,
        interactionMode: .momentary,
        action: .localAIDictation()
      ),
      configurationID: configuration.id
    )
    let runtime = ControllerRuntime(
      queue: DispatchQueue(
        label: "runtime-action-availability-test"
      ),
      profile: profile,
      executor: executor,
      onSnapshot: { snapshots.append($0) }
    )
    let deviceID = DeviceID(rawValue: "pedal")
    runtime.connect(connection(deviceID))
    runtime.setActionExecutionAvailability(
      ActionExecutionAvailability(
        dictationAllowed: false,
        localAIDictationAllowed: true,
        keyboardShortcutsAllowed: false
      )
    )

    runtime.handle(
      ControlEvent(
        deviceID: deviceID,
        controlID: .left,
        phase: .pressed,
        timestampNanoseconds: 1
      )
    )
    runtime.handle(
      event(
        deviceID: deviceID,
        phase: .pressed,
        timestamp: 2
      )
    )
    runtime.handle(
      ControlEvent(
        deviceID: deviceID,
        controlID: .right,
        phase: .pressed,
        timestampNanoseconds: 3
      )
    )
    runtime.flush()

    #expect(
      executor.invocations.map(\.action.kind) == [.localAIDictation]
    )
    #expect(
      snapshots.latest?.devices.first?.pressedControls
        == [.left, .center, .right]
    )
  }

  /// Resolves each connected Device through its own model configuration.
  @Test
  func connectedDeviceModelsUseIndependentBindings() {
    let otherModel = DeviceModelID(rawValue: "test_control_surface")
    let profile = Profile(
      name: "Studio",
      deviceConfigurations: [
        ProfileDeviceConfiguration(
          matchRule: DeviceMatchRule(modelID: .vecInfinity3),
          bindings: [
            Binding(
              controlID: .center,
              interactionMode: .momentary,
              action: .dictation()
            )
          ]
        ),
        ProfileDeviceConfiguration(
          matchRule: DeviceMatchRule(modelID: otherModel),
          bindings: [
            Binding(
              controlID: .center,
              interactionMode: .momentary,
              action: .keyboardShortcut(
                KeyboardShortcut(keyCode: 49, modifiers: [])
              )
            )
          ]
        ),
      ]
    )
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = ControllerRuntime(
      queue: DispatchQueue(label: "runtime-multi-model-test"),
      profile: profile,
      executor: executor,
      onSnapshot: { snapshots.append($0) }
    )
    let pedalID = DeviceID(rawValue: "pedal")
    let surfaceID = DeviceID(rawValue: "surface")
    runtime.connect(connection(pedalID))
    runtime.connect(connection(surfaceID, modelID: otherModel))
    runtime.setActionExecutionAllowed(true)

    runtime.handle(
      event(deviceID: pedalID, phase: .pressed, timestamp: 1)
    )
    runtime.handle(
      event(deviceID: surfaceID, phase: .pressed, timestamp: 2)
    )
    runtime.flush()

    #expect(
      executor.invocations.map(\.action.kind)
        == [.dictation, .keyboardShortcut]
    )
  }

  /// Ends active ownership before acknowledging a Profile replacement.
  @Test
  func profileSwitchEndsActiveActionAndRequiresNewPress() async {
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = makeRuntime(
      executor: executor,
      snapshots: snapshots
    )
    let deviceID = DeviceID(rawValue: "pedal")
    runtime.connect(connection(deviceID))
    runtime.setActionExecutionAllowed(true)
    runtime.handle(
      event(deviceID: deviceID, phase: .pressed, timestamp: 1)
    )
    runtime.flush()

    await runtime.setProfile(.defaultProfile)
    runtime.handle(
      event(deviceID: deviceID, phase: .released, timestamp: 2)
    )
    runtime.handle(
      event(deviceID: deviceID, phase: .pressed, timestamp: 3)
    )
    runtime.flush()

    #expect(
      executor.invocations.map(\.phase) == [.begin, .end, .begin]
    )
  }

  @Test
  func trustedMomentaryPathBeginsEndsAndMeasuresLatency() {
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = makeRuntime(
      executor: executor,
      snapshots: snapshots
    )
    let deviceID = DeviceID(rawValue: "pedal")
    let now = MonotonicClock.nowNanoseconds()

    runtime.connect(connection(deviceID))
    runtime.setActionExecutionAllowed(true)
    runtime.handle(
      event(
        deviceID: deviceID,
        phase: .pressed,
        timestamp: now
      )
    )
    runtime.handle(
      event(
        deviceID: deviceID,
        phase: .released,
        timestamp: now
      )
    )
    runtime.flush()

    #expect(executor.invocations.map(\.phase) == [.begin, .end])
    #expect(
      snapshots.latest?.lastDispatchLatencyNanoseconds != nil
    )
  }

  @Test
  func disconnectEndsAnActiveAction() {
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = makeRuntime(
      executor: executor,
      snapshots: snapshots
    )
    let deviceID = DeviceID(rawValue: "pedal")

    runtime.connect(connection(deviceID))
    runtime.setActionExecutionAllowed(true)
    runtime.handle(
      event(
        deviceID: deviceID,
        phase: .pressed,
        timestamp: MonotonicClock.nowNanoseconds()
      )
    )
    runtime.disconnect(deviceID: deviceID)
    runtime.flush()

    #expect(executor.invocations.map(\.phase) == [.begin, .end])
    #expect(snapshots.latest?.devices.isEmpty == true)
  }

  /// Ends active Actions for sleep without permanently stopping the executor.
  @Test
  func suspensionEndsActiveActionsAndForgetsDevices() {
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = makeRuntime(
      executor: executor,
      snapshots: snapshots
    )
    let deviceID = DeviceID(rawValue: "pedal")

    runtime.connect(connection(deviceID))
    runtime.setActionExecutionAllowed(true)
    runtime.handle(
      event(
        deviceID: deviceID,
        phase: .pressed,
        timestamp: MonotonicClock.nowNanoseconds()
      )
    )
    runtime.flush()
    runtime.suspend()

    #expect(executor.invocations.map(\.phase) == [.begin, .end])
    #expect(snapshots.latest?.devices.isEmpty == true)

    runtime.connect(connection(deviceID))
    runtime.handle(
      event(
        deviceID: deviceID,
        phase: .pressed,
        timestamp: MonotonicClock.nowNanoseconds()
      )
    )
    runtime.flush()
    #expect(
      executor.invocations.map(\.phase)
        == [.begin, .end, .begin]
    )
  }

  @Test
  func permissionRevocationClearsAnActiveAction() {
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = makeRuntime(
      executor: executor,
      snapshots: snapshots
    )
    let deviceID = DeviceID(rawValue: "pedal")

    runtime.connect(connection(deviceID))
    runtime.setActionExecutionAllowed(true)
    runtime.handle(
      event(
        deviceID: deviceID,
        phase: .pressed,
        timestamp: MonotonicClock.nowNanoseconds()
      )
    )
    runtime.flush()
    runtime.setActionExecutionAllowed(false)
    runtime.flush()

    #expect(executor.invocations.map(\.phase) == [.begin, .end])
    #expect(
      snapshots.latest?.devices.first?.activeControls.isEmpty == true
    )
  }

  @Test
  func executorFailureIsPublished() {
    let executor = FailingActionExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = ControllerRuntime(
      queue: DispatchQueue(label: "runtime-failure-test"),
      profile: .defaultProfile,
      executor: executor,
      onSnapshot: { snapshots.append($0) }
    )
    let deviceID = DeviceID(rawValue: "pedal")

    runtime.connect(connection(deviceID))
    runtime.setActionExecutionAllowed(true)
    runtime.handle(
      event(deviceID: deviceID, phase: .pressed, timestamp: 1)
    )
    runtime.flush()

    #expect(
      snapshots.latest?.lastActionDispatchSucceeded == false
    )
    #expect(
      snapshots.latest?.devices.first?.activeControls.isEmpty == true
    )
  }

  @Test
  func asynchronousFailureResetsToggleOwnership() throws {
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    var profile = Profile.defaultProfile
    let configuration = try #require(
      profile.configuration(
        matching: DeviceMatchRule(modelID: .vecInfinity3)
      )
    )
    try profile.setBinding(
      Binding(
        controlID: .center,
        interactionMode: .toggle,
        action: .dictation()
      ),
      configurationID: configuration.id
    )
    let runtime = ControllerRuntime(
      queue: DispatchQueue(label: "runtime-async-failure-test"),
      profile: profile,
      executor: executor,
      onSnapshot: { snapshots.append($0) }
    )
    let deviceID = DeviceID(rawValue: "pedal")

    runtime.connect(connection(deviceID))
    runtime.setActionExecutionAllowed(true)
    runtime.handle(
      event(deviceID: deviceID, phase: .pressed, timestamp: 1)
    )
    runtime.handle(
      event(deviceID: deviceID, phase: .released, timestamp: 2)
    )
    runtime.actionDidFail(.dictation)
    runtime.handle(
      event(deviceID: deviceID, phase: .pressed, timestamp: 3)
    )
    runtime.flush()

    #expect(executor.invocations.map(\.phase) == [.begin, .begin])
    #expect(
      snapshots.latest?.lastActionDispatchSucceeded == true
    )
  }

  /// Preserves an accepted dispatch result when later Action work fails.
  @Test
  func asynchronousFailureDoesNotBecomeADispatchFailure() {
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = makeRuntime(
      executor: executor,
      snapshots: snapshots
    )
    let deviceID = DeviceID(rawValue: "pedal")

    runtime.connect(connection(deviceID))
    runtime.setActionExecutionAllowed(true)
    runtime.handle(
      event(deviceID: deviceID, phase: .pressed, timestamp: 1)
    )
    runtime.flush()
    #expect(
      snapshots.latest?.lastActionDispatchSucceeded == true
    )

    runtime.actionDidFail(.dictation)
    runtime.flush()

    #expect(
      snapshots.latest?.lastActionDispatchSucceeded == true
    )
    #expect(
      snapshots.latest?.devices.first?.activeControls.isEmpty == true
    )
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "HC_RUN_HID_PERFORMANCE"
      ] == "1"
    )
  )
  func tenThousandTransitionSoakMeetsDispatchBudget() {
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = makeRuntime(
      executor: executor,
      snapshots: snapshots
    )
    let deviceID = DeviceID(rawValue: "soak-pedal")

    runtime.connect(connection(deviceID))
    runtime.setActionExecutionAllowed(true)
    runtime.flush()

    for _ in 0..<5_000 {
      runtime.handle(
        event(
          deviceID: deviceID,
          phase: .pressed,
          timestamp: MonotonicClock.nowNanoseconds()
        )
      )
      runtime.handle(
        event(
          deviceID: deviceID,
          phase: .released,
          timestamp: MonotonicClock.nowNanoseconds()
        )
      )
      runtime.flush()
    }

    let invocations = executor.invocations
    let latencies = executor.dispatchLatencies.sorted()
    let p50 = percentile(0.50, in: latencies)
    let p95 = percentile(0.95, in: latencies)
    let p99 = percentile(0.99, in: latencies)
    let maximum = latencies.last ?? .max

    print(
      """
      10,000-transition latency: \
      p50=\(milliseconds(p50))ms, \
      p95=\(milliseconds(p95))ms, \
      p99=\(milliseconds(p99))ms, \
      max=\(milliseconds(maximum))ms
      """
    )

    #expect(invocations.count == 10_000)
    #expect(latencies.count == 10_000)
    #expect(
      invocations.enumerated().allSatisfy { index, invocation in
        invocation.phase == (index.isMultiple(of: 2) ? .begin : .end)
      }
    )
    #expect(p50 <= 3_000_000)
    #expect(p95 <= 8_000_000)
    #expect(p99 <= 15_000_000)
    #expect(maximum <= 30_000_000)
    #expect(
      snapshots.latest?.devices.first?.pressedControls.isEmpty == true
    )
    #expect(
      snapshots.latest?.devices.first?.activeControls.isEmpty == true
    )
  }

  @Test
  func snapshotIncludesActiveStateForEveryConnectedDevice() throws {
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = makeRuntime(
      executor: executor,
      snapshots: snapshots
    )
    let firstID = DeviceID(rawValue: "controller-a")
    let secondID = DeviceID(rawValue: "controller-b")

    runtime.connect(connection(firstID))
    runtime.connect(connection(secondID))
    runtime.setActionExecutionAllowed(true)
    runtime.handle(
      event(deviceID: secondID, phase: .pressed, timestamp: 1)
    )
    runtime.flush()

    let devices = try #require(snapshots.latest?.devices)
    #expect(devices.map(\.id) == [firstID, secondID])
    #expect(devices[0].activeControls == [.center])
    #expect(devices[1].activeControls == [.center])
  }

  /// Executes an active Profile Binding without a connected physical Device.
  @Test
  func keyboardFallbackWorksWhileDeviceIsDisconnected() throws {
    var profile = Profile.defaultProfile
    let configuration = try #require(profile.deviceConfigurations.first)
    var center = try #require(configuration.binding(for: .center))
    center.activationShortcut = .suggestedControlActivation
    try profile.setBinding(center, configurationID: configuration.id)
    let registration = try #require(
      ProfileBindingResolver(profile: profile).keyboardFallbacks.first
    )
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = ControllerRuntime(
      queue: DispatchQueue(label: "runtime-keyboard-fallback-test"),
      profile: profile,
      executor: executor,
      onSnapshot: { snapshots.append($0) }
    )
    runtime.setActionExecutionAllowed(true)

    runtime.handleKeyboardFallback(
      registration,
      phase: .pressed,
      timestampNanoseconds: 1
    )
    runtime.flush()
    #expect(executor.invocations.map(\.phase) == [.begin])
    #expect(snapshots.latest?.devices.isEmpty == true)
    #expect(snapshots.latest?.hasActiveActions == true)

    runtime.handleKeyboardFallback(
      registration,
      phase: .released,
      timestampNanoseconds: 2
    )
    runtime.flush()
    #expect(executor.invocations.map(\.phase) == [.begin, .end])
    #expect(snapshots.latest?.hasActiveActions == false)
  }

  /// Reflects keyboard-owned Action state on a matching connected Device.
  @Test
  func keyboardFallbackPublishesLogicalControlActivity() throws {
    var profile = Profile.defaultProfile
    let configuration = try #require(profile.deviceConfigurations.first)
    var center = try #require(configuration.binding(for: .center))
    center.activationShortcut = .suggestedControlActivation
    try profile.setBinding(center, configurationID: configuration.id)
    let registration = try #require(
      ProfileBindingResolver(profile: profile).keyboardFallbacks.first
    )
    let executor = RecordingExecutor()
    let snapshots = SnapshotRecorder()
    let runtime = ControllerRuntime(
      queue: DispatchQueue(label: "runtime-fallback-snapshot-test"),
      profile: profile,
      executor: executor,
      onSnapshot: { snapshots.append($0) }
    )
    runtime.connect(connection(DeviceID(rawValue: "pedal")))
    runtime.setActionExecutionAllowed(true)

    runtime.handleKeyboardFallback(
      registration,
      phase: .pressed,
      timestampNanoseconds: 1
    )
    runtime.flush()

    #expect(
      snapshots.latest?.devices.first?.pressedControls.isEmpty == true
    )
    #expect(
      snapshots.latest?.devices.first?.activeControls == [.center]
    )
  }

  private func connection(
    _ deviceID: DeviceID,
    modelID: DeviceModelID = .vecInfinity3
  ) -> HardwareDeviceConnection {
    HardwareDeviceConnection(
      id: deviceID,
      name: "Test Controller",
      model: DeviceModelDescriptor(
        modelID: modelID,
        name: "Test Controller",
        controls: [
          ControlDescriptor(id: .left, name: "First"),
          ControlDescriptor(
            id: .center,
            name: "Primary",
            visualWeight: .prominent
          ),
          ControlDescriptor(id: .right, name: "Last"),
        ]
      )
    )
  }

  private func makeRuntime(
    executor: RecordingExecutor,
    snapshots: SnapshotRecorder
  ) -> ControllerRuntime<RecordingExecutor> {
    ControllerRuntime(
      queue: DispatchQueue(label: "runtime-tests"),
      profile: .defaultProfile,
      executor: executor,
      onSnapshot: { snapshots.append($0) }
    )
  }

  private func event(
    deviceID: DeviceID,
    phase: ControlPhase,
    timestamp: UInt64
  ) -> ControlEvent {
    ControlEvent(
      deviceID: deviceID,
      controlID: .center,
      phase: phase,
      timestampNanoseconds: timestamp
    )
  }

  private func percentile(
    _ percentile: Double,
    in sortedValues: [UInt64]
  ) -> UInt64 {
    guard !sortedValues.isEmpty else {
      return .max
    }
    let index = Int(
      (Double(sortedValues.count - 1) * percentile)
        .rounded(.up)
    )
    return sortedValues[index]
  }

  private func milliseconds(_ nanoseconds: UInt64) -> String {
    String(format: "%.3f", Double(nanoseconds) / 1_000_000)
  }
}

private struct FailingActionExecutor: ActionExecuting {
  func execute(_ invocation: ActionInvocation) -> Bool {
    false
  }
}

private final class RecordingExecutor:
  ActionExecuting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storage: [ActionInvocation] = []
  private var latencyStorage: [UInt64] = []

  var invocations: [ActionInvocation] {
    lock.withLock { storage }
  }

  var dispatchLatencies: [UInt64] {
    lock.withLock { latencyStorage }
  }

  func execute(_ invocation: ActionInvocation) -> Bool {
    let now = MonotonicClock.nowNanoseconds()
    let latency =
      now >= invocation.inputTimestampNanoseconds
      ? now - invocation.inputTimestampNanoseconds
      : 0
    lock.withLock {
      storage.append(invocation)
      latencyStorage.append(latency)
    }
    return true
  }
}

private final class SnapshotRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: RuntimeSnapshot?

  var latest: RuntimeSnapshot? {
    lock.withLock { storage }
  }

  func append(_ snapshot: RuntimeSnapshot) {
    lock.withLock {
      storage = snapshot
    }
  }
}
