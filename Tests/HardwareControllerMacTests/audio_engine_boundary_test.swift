import AVFoundation
import Foundation
import Testing

@testable import HardwareControllerMac

struct AudioEngineBoundaryTest {
  /// Hides AVFAudio's process-scoped aggregate while retaining stable Devices.
  @Test
  func processAggregateIsNotSelectable() {
    let processAggregate = AudioInputDevice(
      uniqueID: "CADefaultDeviceAggregate-12345-0",
      name: "CADefaultDeviceAggregate-12345-0"
    )
    let physicalInput = AudioInputDevice(
      uniqueID: "BuiltInMicrophoneDevice",
      name: "MacBook Pro Microphone"
    )

    #expect(processAggregate.isStableSelection == false)
    #expect(physicalInput.isStableSelection)
  }

  /// Enumerates a mixed real CoreAudio graph without failing on output Devices.
  @Test
  func listsCurrentSystemInputs() throws {
    _ = try SystemAudioInputDeviceDiscovery()
      .availableInputDevices()
  }

  /// Pins explicit app-local inputs without pinning the negotiated system route.
  @Test
  func onlyExplicitMicrophoneSelectionPinsTheAudioUnit() {
    let route = AudioInputRoute(
      deviceID: 42,
      sampleRate: 48_000,
      channelCount: 1
    )

    #expect(
      SystemAudioEnvironment.pinnedDeviceID(
        for: route,
        preferredDeviceUID: nil
      ) == nil
    )
    #expect(
      SystemAudioEnvironment.pinnedDeviceID(
        for: route,
        preferredDeviceUID: "explicit-device"
      ) == route.deviceID
    )
  }

  /// Rebuilds prepared audio resources when the input route changes.
  @Test
  func captureUsesCurrentRouteAfterPreparationChange() throws {
    let firstRoute = AudioInputRoute(
      deviceID: 1,
      sampleRate: 44_100,
      channelCount: 1
    )
    let secondRoute = AudioInputRoute(
      deviceID: 2,
      sampleRate: 48_000,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(
      route: firstRoute
    )
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )

    try boundary.prepare()
    environment.changeRoute(to: secondRoute)
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {}
    )

    #expect(environment.startedRoutes == [secondRoute])
    boundary.stop()
  }

  /// Retains stopped invalid generations until route callbacks cannot race teardown.
  @Test
  func routeChangeRetiresThePreviousEngineWithoutDeallocation() throws {
    let firstRoute = AudioInputRoute(
      deviceID: 1,
      sampleRate: 16_000,
      channelCount: 1
    )
    let secondRoute = AudioInputRoute(
      deviceID: 2,
      sampleRate: 48_000,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(
      route: firstRoute
    )
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )

    try boundary.prepare()
    environment.changeRoute(to: secondRoute)
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {}
    )

    #expect(environment.deinitializedEngineCount == 0)
    boundary.stop()
  }

  /// Detects rate and channel changes even when notification delivery is late.
  @Test
  func captureRevalidatesTheCompleteRouteBeforeEveryStart() throws {
    let initialRoute = AudioInputRoute(
      deviceID: 1,
      sampleRate: 44_100,
      channelCount: 1
    )
    let changedRate = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let changedChannels = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 2
    )
    let environment = FakeAudioSystemEnvironment(
      route: initialRoute
    )
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )

    try boundary.prepare()
    environment.changeRouteSilently(to: changedRate)
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {}
    )
    boundary.stop()
    environment.changeRouteSilently(to: changedChannels)
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {}
    )

    #expect(
      environment.startedRoutes
        == [changedRate, changedChannels]
    )
    boundary.stop()
  }

  /// Discards a failed engine generation before a later retry.
  @Test
  func failedStartRebuildsTheEngineBeforeRetrying() throws {
    let route = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(route: route)
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )
    environment.failNextStart()

    #expect(throws: FakeAudioEngineError.startFailed) {
      try boundary.startCapture(
        onBuffer: { _ in },
        onConfigurationChange: {}
      )
    }
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {}
    )

    #expect(environment.engineCreationCount == 2)
    #expect(environment.startedRoutes == [route])
    boundary.stop()
  }

  /// Discards an engine generation after failed warm preparation.
  @Test
  func failedPreparationRebuildsTheEngineBeforeRetrying() throws {
    let route = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(route: route)
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )
    environment.failNextPreparation()

    #expect(throws: FakeAudioEngineError.preparationFailed) {
      try boundary.prepare()
    }
    try boundary.prepare()

    #expect(environment.engineCreationCount == 2)
  }

  /// Discards an engine generation after incomplete cleanup.
  @Test
  func failedStopRebuildsTheEngineBeforeRetrying() throws {
    let route = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(route: route)
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {}
    )
    environment.failNextStop()

    boundary.stop()
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {}
    )

    #expect(environment.engineCreationCount == 2)
    boundary.stop()
  }

  /// Fails one active stream once when redundant invalidations arrive.
  @Test
  func repeatedInvalidationsFailActiveCaptureOnce() throws {
    let route = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(route: route)
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )
    let failures = LockedCounter()
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {
        failures.increment()
      }
    )

    environment.publishRouteChange()
    environment.publishEngineConfigurationChange()

    #expect(failures.value == 1)
    boundary.stop()
  }

  /// Keeps capture active when AVFAudio settles without changing the input route.
  @Test
  func unchangedEngineConfigurationRecoversWithoutFailingCapture() throws {
    let route = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(route: route)
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )
    let failures = LockedCounter()
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {
        failures.increment()
      }
    )

    environment.publishEngineConfigurationChange()

    #expect(failures.value == 0)
    #expect(environment.engineRecoveryCount == 1)
    boundary.stop()
  }

  /// Invalidates an active engine when its route changed before notification.
  @Test
  func engineConfigurationDetectsASilentlyChangedRoute() throws {
    let firstRoute = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let secondRoute = AudioInputRoute(
      deviceID: 2,
      sampleRate: 44_100,
      channelCount: 2
    )
    let environment = FakeAudioSystemEnvironment(route: firstRoute)
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )
    let failures = LockedCounter()
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {
        failures.increment()
      }
    )

    environment.changeRouteSilently(to: secondRoute)
    environment.publishEngineConfigurationChange()

    #expect(failures.value == 1)
    #expect(environment.engineRecoveryCount == 0)
    boundary.stop()
  }

  /// Discards a generation when unchanged-route recovery cannot restart it.
  @Test
  func failedEngineRecoveryFailsOnceAndRebuildsOnRetry() throws {
    let route = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(route: route)
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )
    let failures = LockedCounter()
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {
        failures.increment()
      }
    )

    environment.publishEngineRecoveryFailure()
    environment.publishEngineRecoveryFailure()

    #expect(failures.value == 1)
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {}
    )
    #expect(environment.engineCreationCount == 2)
    boundary.stop()
  }

  /// Fails closed when the default-input observer cannot be installed.
  @Test
  func unavailableRouteObservationPreventsCapture() {
    let route = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(
      route: route,
      observationError: FakeAudioEngineError.observationFailed
    )
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )

    do {
      try boundary.prepare()
      Issue.record("Expected route observation to fail closed.")
    } catch {
      guard
        case .couldNotMonitorInput =
          error as? MicrophoneCaptureError
      else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
  }

  /// Retries a transient observer-registration failure on later preparation.
  @Test
  func transientRouteObservationFailureRecovers() throws {
    let route = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(
      route: route,
      transientObservationFailures: 1
    )
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )

    try boundary.prepare()

    #expect(environment.engineCreationCount == 1)
  }

  /// Retries a transient Device-listener rebind failure on later preparation.
  @Test
  func transientRouteRefreshFailureRecovers() throws {
    let route = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(
      route: route,
      transientRefreshFailures: 1
    )
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )

    do {
      try boundary.prepare()
      Issue.record("Expected the first refresh to fail.")
    } catch {
      guard
        case .couldNotMonitorInput =
          error as? MicrophoneCaptureError
      else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
    try boundary.prepare()

    #expect(environment.engineCreationCount == 1)
  }

  /// Preserves route alignment across sustained configuration churn.
  @Test
  func repeatedRouteChangesNeverReuseAStaleEngine() throws {
    let initialRoute = AudioInputRoute(
      deviceID: 1,
      sampleRate: 44_100,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(
      route: initialRoute
    )
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )

    for index in 1...1_000 {
      let route = AudioInputRoute(
        deviceID: UInt32(index + 1),
        sampleRate: index.isMultiple(of: 2)
          ? 44_100 : 48_000,
        channelCount: UInt32((index % 2) + 1)
      )
      environment.changeRoute(to: route)
      try boundary.startCapture(
        onBuffer: { _ in },
        onConfigurationChange: {}
      )
      boundary.stop()
    }

    #expect(environment.startedRoutes.count == 1_000)
    #expect(
      environment.startedRoutes
        == environment.createdRoutes
    )
  }

  /// Rebuilds prepared resources against an explicit app-local selection.
  @Test
  func explicitSelectionRebuildsThePreparedEngine() throws {
    let defaultRoute = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let usbRoute = AudioInputRoute(
      deviceID: 2,
      sampleRate: 44_100,
      channelCount: 2
    )
    let environment = FakeAudioSystemEnvironment(
      route: defaultRoute,
      selectableRoutes: ["usb-microphone": usbRoute]
    )
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )

    try boundary.prepare()
    boundary.selectInputDevice(uniqueID: "usb-microphone")
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {}
    )

    #expect(environment.createdRoutes == [defaultRoute, usbRoute])
    #expect(environment.startedRoutes == [usbRoute])
    boundary.stop()
  }

  /// Falls back to the system route while a saved Device is disconnected.
  @Test
  func unavailableSelectionUsesTheDefaultRoute() throws {
    let defaultRoute = AudioInputRoute(
      deviceID: 1,
      sampleRate: 48_000,
      channelCount: 1
    )
    let environment = FakeAudioSystemEnvironment(route: defaultRoute)
    let boundary = ConfigurationAwareAudioEngineBoundary(
      environment: environment
    )

    boundary.selectInputDevice(uniqueID: "disconnected-microphone")
    try boundary.startCapture(
      onBuffer: { _ in },
      onConfigurationChange: {}
    )

    #expect(environment.startedRoutes == [defaultRoute])
    boundary.stop()
  }
}

private final class FakeAudioSystemEnvironment:
  AudioSystemEnvironment,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var route: AudioInputRoute
  private var routeChangeHandler: (@Sendable () -> Void)?
  private var engineConfigurationHandlers:
    [@Sendable () -> AudioEngineConfigurationChangeDisposition] = []
  private var engineRecoveryFailureHandlers: [@Sendable () -> Void] = []
  private var engineRecoveryCountStorage = 0
  private var startedRouteStorage: [AudioInputRoute] = []
  private var createdRouteStorage: [AudioInputRoute] = []
  private var deinitializedEngineCountStorage = 0
  private var pendingPreparationFailures = 0
  private var pendingObservationFailures: Int
  private var pendingRefreshFailures: Int
  private var pendingStartFailures = 0
  private var pendingStopFailures = 0
  private let observationError: (any Error)?
  private let defaultRoute: AudioInputRoute
  private let selectableRoutes: [String: AudioInputRoute]
  private var preferredDeviceUID: String?

  init(
    route: AudioInputRoute,
    selectableRoutes: [String: AudioInputRoute] = [:],
    observationError: (any Error)? = nil,
    transientObservationFailures: Int = 0,
    transientRefreshFailures: Int = 0
  ) {
    self.route = route
    defaultRoute = route
    self.selectableRoutes = selectableRoutes
    self.observationError = observationError
    pendingObservationFailures =
      transientObservationFailures
    pendingRefreshFailures = transientRefreshFailures
  }

  var startedRoutes: [AudioInputRoute] {
    lock.withLock { startedRouteStorage }
  }

  var createdRoutes: [AudioInputRoute] {
    lock.withLock { createdRouteStorage }
  }

  var engineCreationCount: Int {
    lock.withLock { createdRouteStorage.count }
  }

  var deinitializedEngineCount: Int {
    lock.withLock { deinitializedEngineCountStorage }
  }

  var engineRecoveryCount: Int {
    lock.withLock { engineRecoveryCountStorage }
  }

  /// Returns the current fake system input route.
  func currentInputRoute() throws -> AudioInputRoute {
    lock.withLock { route }
  }

  /// Returns stable descriptors for every selectable fake route.
  func availableInputDevices() throws -> [AudioInputDevice] {
    selectableRoutes.keys.sorted().map {
      AudioInputDevice(uniqueID: $0, name: $0)
    }
  }

  /// Applies a fake preferred route without publishing a system event.
  func setPreferredInputDeviceUID(_ uniqueID: String?) -> Bool {
    lock.withLock {
      guard preferredDeviceUID != uniqueID else {
        return false
      }
      preferredDeviceUID = uniqueID
      route = uniqueID.flatMap { selectableRoutes[$0] } ?? defaultRoute
      return true
    }
  }

  /// Creates one engine bound to the route current at creation.
  func makeEngine(
    for route: AudioInputRoute,
    onConfigurationChange:
      @escaping @Sendable () -> AudioEngineConfigurationChangeDisposition,
    onRecoveryFailure:
      @escaping @Sendable () -> Void
  ) -> any AudioEngineSession {
    lock.withLock {
      createdRouteStorage.append(route)
      engineConfigurationHandlers.append(
        onConfigurationChange
      )
      engineRecoveryFailureHandlers.append(
        onRecoveryFailure
      )
    }
    return FakeAudioEngineSession(
      route: route,
      currentRoute: { [weak self] in
        guard let self else {
          return route
        }
        return lock.withLock { self.route }
      },
      onStart: { [weak self] startedRoute in
        guard let self else {
          return
        }
        lock.withLock {
          startedRouteStorage.append(startedRoute)
        }
      },
      shouldFailStart: { [weak self] in
        guard let self else {
          return false
        }
        return lock.withLock {
          guard pendingStartFailures > 0 else {
            return false
          }
          pendingStartFailures -= 1
          return true
        }
      },
      shouldFailPreparation: { [weak self] in
        guard let self else {
          return false
        }
        return lock.withLock {
          guard pendingPreparationFailures > 0 else {
            return false
          }
          pendingPreparationFailures -= 1
          return true
        }
      },
      shouldFailStop: { [weak self] in
        guard let self else {
          return false
        }
        return lock.withLock {
          guard pendingStopFailures > 0 else {
            return false
          }
          pendingStopFailures -= 1
          return true
        }
      },
      onDeinit: { [weak self] in
        guard let self else {
          return
        }
        lock.withLock {
          deinitializedEngineCountStorage += 1
        }
      }
    )
  }

  /// Retains the route-change callback for deterministic delivery.
  func observeInputRouteChanges(
    _ handler: @escaping @Sendable () -> Void
  ) throws -> any AudioInputRouteObservation {
    if let observationError {
      throw observationError
    }
    try lock.withLock {
      guard pendingObservationFailures == 0 else {
        pendingObservationFailures -= 1
        throw FakeAudioEngineError.observationFailed
      }
      routeChangeHandler = handler
    }
    return FakeAudioInputRouteObservation { [weak self] in
      guard let self else {
        return
      }
      try lock.withLock {
        guard pendingRefreshFailures > 0 else {
          return
        }
        pendingRefreshFailures -= 1
        throw FakeAudioEngineError.observationFailed
      }
    }
  }

  /// Changes the route and synchronously publishes the system event.
  func changeRoute(to route: AudioInputRoute) {
    let handler = lock.withLock {
      self.route = route
      return routeChangeHandler
    }
    handler?()
  }

  /// Changes the route without publishing its observation callback.
  func changeRouteSilently(to route: AudioInputRoute) {
    lock.withLock {
      self.route = route
    }
  }

  /// Publishes the retained route callback without changing the route.
  func publishRouteChange() {
    let handler = lock.withLock { routeChangeHandler }
    handler?()
  }

  /// Publishes configuration changes from every created engine.
  func publishEngineConfigurationChange() {
    let handlers = lock.withLock {
      engineConfigurationHandlers
    }
    for handler in handlers {
      if handler() == .recover {
        lock.withLock {
          engineRecoveryCountStorage += 1
        }
      }
    }
  }

  /// Publishes a failed automatic recovery from every created engine.
  func publishEngineRecoveryFailure() {
    let handlers = lock.withLock {
      engineRecoveryFailureHandlers
    }
    for handler in handlers {
      handler()
    }
  }

  /// Makes the next fake engine start fail.
  func failNextStart() {
    lock.withLock {
      pendingStartFailures += 1
    }
  }

  /// Makes the next fake engine preparation fail.
  func failNextPreparation() {
    lock.withLock {
      pendingPreparationFailures += 1
    }
  }

  /// Makes the next fake engine stop require discard.
  func failNextStop() {
    lock.withLock {
      pendingStopFailures += 1
    }
  }
}

private final class FakeAudioEngineSession:
  AudioEngineSession,
  @unchecked Sendable
{
  private let route: AudioInputRoute
  private let currentRoute: @Sendable () -> AudioInputRoute
  private let onStart: @Sendable (AudioInputRoute) -> Void
  private let shouldFailPreparation: @Sendable () -> Bool
  private let shouldFailStart: @Sendable () -> Bool
  private let shouldFailStop: @Sendable () -> Bool
  private let onDeinit: @Sendable () -> Void

  /// Retains deterministic fake behavior and lifecycle observation.
  init(
    route: AudioInputRoute,
    currentRoute: @escaping @Sendable () -> AudioInputRoute,
    onStart: @escaping @Sendable (AudioInputRoute) -> Void,
    shouldFailStart: @escaping @Sendable () -> Bool,
    shouldFailPreparation: @escaping @Sendable () -> Bool,
    shouldFailStop: @escaping @Sendable () -> Bool,
    onDeinit: @escaping @Sendable () -> Void
  ) {
    self.route = route
    self.currentRoute = currentRoute
    self.onStart = onStart
    self.shouldFailStart = shouldFailStart
    self.shouldFailPreparation = shouldFailPreparation
    self.shouldFailStop = shouldFailStop
    self.onDeinit = onDeinit
  }

  deinit {
    onDeinit()
  }

  var inputFormat: AVAudioFormat? {
    AVAudioFormat(
      standardFormatWithSampleRate: route.sampleRate,
      channels: AVAudioChannelCount(route.channelCount)
    )
  }

  /// Primes the fake engine without starting capture.
  func prepare() throws {
    guard !shouldFailPreparation() else {
      throw FakeAudioEngineError.preparationFailed
    }
  }

  /// Rejects stale engines exactly as AVFAudio does.
  func startCapture(
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) throws {
    guard currentRoute() == route else {
      throw FakeAudioEngineError.staleConfiguration
    }
    guard !shouldFailStart() else {
      throw FakeAudioEngineError.startFailed
    }
    onStart(route)
  }

  /// Stops the fake engine.
  func stop() -> AudioEngineStopResult {
    shouldFailStop() ? .discard : .reusable
  }

  /// Retires fake callbacks without changing deterministic behavior.
  func retire() {}
}

private final class FakeAudioInputRouteObservation:
  AudioInputRouteObservation,
  @unchecked Sendable
{
  private let onRefresh: @Sendable () throws -> Void

  /// Retains a deterministic refresh implementation.
  init(onRefresh: @escaping @Sendable () throws -> Void) {
    self.onRefresh = onRefresh
  }

  /// Runs the injected Device-listener refresh.
  func refresh() throws {
    try onRefresh()
  }
}

private enum FakeAudioEngineError: Error {
  case observationFailed
  case preparationFailed
  case staleConfiguration
  case startFailed
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int {
    lock.withLock { storage }
  }

  /// Increments the counter under its lock.
  func increment() {
    lock.withLock {
      storage += 1
    }
  }
}
