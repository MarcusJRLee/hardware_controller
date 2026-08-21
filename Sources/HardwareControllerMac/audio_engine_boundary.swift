@preconcurrency import AVFoundation
import AudioToolbox
@preconcurrency import CoreAudio
import Dispatch
import Foundation
import HardwareControllerAudioBoundary
import HardwareControllerCore
import Synchronization
import os

/// Identifies one selectable local microphone without persisting CoreAudio IDs.
public struct AudioInputDevice: Equatable, Hashable, Sendable {
  public let uniqueID: String
  public let name: String

  /// Creates one stable user-facing microphone descriptor.
  public init(uniqueID: String, name: String) {
    self.uniqueID = uniqueID
    self.name = name
  }

  /// Rejects AVFAudio's process-scoped aggregate from persisted choices.
  var isStableSelection: Bool {
    !uniqueID.hasPrefix("CADefaultDeviceAggregate-")
  }
}

/// Lists the microphones currently available to the application.
public protocol AudioInputDeviceDiscovering: Sendable {
  /// Returns local input Devices sorted for stable presentation.
  func availableInputDevices() throws -> [AudioInputDevice]
}

/// Discovers input Devices through the CoreAudio object graph.
public struct SystemAudioInputDeviceDiscovery:
  AudioInputDeviceDiscovering
{
  public init() {}

  /// Returns every current Device that exposes at least one input channel.
  public func availableInputDevices() throws -> [AudioInputDevice] {
    try SystemAudioEnvironment().availableInputDevices()
  }
}

/// Identifies one concrete system microphone configuration.
struct AudioInputRoute: Equatable, Sendable {
  let deviceID: UInt32
  let sampleRate: Float64
  let channelCount: UInt32
}

/// Retains one system input-route observation until deinitialization.
protocol AudioInputRouteObservation: AnyObject, Sendable {
  /// Rebinds observation to the current default input when required.
  func refresh() throws
}

/// Provides the complete capture lifecycle used by the microphone actor.
protocol AudioEngineControlling: Sendable {
  /// Selects one stable microphone UID, or follows the system default with nil.
  func selectInputDevice(uniqueID: String?)

  /// Primes current audio resources without capturing.
  func prepare() throws

  /// Starts one capture and reports configuration invalidation.
  func startCapture(
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
    onConfigurationChange:
      @escaping @Sendable () -> Void
  ) throws

  /// Stops the active capture.
  func stop()
}

/// Isolates system audio discovery and engine construction.
protocol AudioSystemEnvironment: Sendable {
  /// Returns selectable input Devices without exposing ephemeral object IDs.
  func availableInputDevices() throws -> [AudioInputDevice]

  /// Changes the preferred microphone and reports an effective selection change.
  func setPreferredInputDeviceUID(_ uniqueID: String?) -> Bool

  /// Returns the current default microphone configuration.
  func currentInputRoute() throws -> AudioInputRoute

  /// Creates one engine pinned to the acquired input route.
  func makeEngine(
    for route: AudioInputRoute,
    onConfigurationChange:
      @escaping @Sendable () -> AudioEngineConfigurationChangeDisposition,
    onRecoveryFailure:
      @escaping @Sendable () -> Void
  ) throws -> any AudioEngineSession

  /// Observes default microphone route changes.
  func observeInputRouteChanges(
    _ handler: @escaping @Sendable () -> Void
  ) throws -> any AudioInputRouteObservation
}

/// Owns one non-restartable system audio-engine generation.
protocol AudioEngineSession: AnyObject, Sendable {
  /// Returns the hardware-facing microphone format when available.
  var inputFormat: AVAudioFormat? { get }

  /// Primes the stopped engine.
  func prepare() throws

  /// Installs one tap and starts capture.
  func startCapture(
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) throws

  /// Stops capture and reports whether this generation remains reusable.
  func stop() -> AudioEngineStopResult

  /// Detaches callbacks before the stopped generation is retained inertly.
  func retire()
}

/// Describes whether a stopped engine generation is safe to reuse.
enum AudioEngineStopResult: Equatable, Sendable {
  case reusable
  case discard
}

/// Distinguishes a recoverable AVFAudio transition from a changed input route.
enum AudioEngineConfigurationChangeDisposition: Equatable, Sendable {
  case recover
  case invalidate
}

/// Rebuilds system audio resources before a changed route can capture.
final class ConfigurationAwareAudioEngineBoundary:
  AudioEngineControlling,
  @unchecked Sendable
{
  private struct SessionLease {
    let session: any AudioEngineSession
    let route: AudioInputRoute
    let generation: UInt64
  }

  private struct EventState {
    var generation: UInt64 = 0
    var activeChangeHandler: (@Sendable () -> Void)?
  }

  private let environment: any AudioSystemEnvironment
  private let eventState = Mutex(EventState())
  private var routeObservation: (any AudioInputRouteObservation)?
  private var routeObservationFailure: String?
  private var session: (any AudioEngineSession)?
  private var sessionGeneration: UInt64?
  private var sessionRoute: AudioInputRoute?
  private var retiredSessions: [any AudioEngineSession] = []
  private static let acquisitionAttemptLimit = 3

  /// Creates the boundary and begins observing route changes.
  init(environment: any AudioSystemEnvironment) {
    self.environment = environment
    installRouteObservation()
  }

  /// Invalidates prepared or active work after an effective selection change.
  func selectInputDevice(uniqueID: String?) {
    guard environment.setPreferredInputDeviceUID(uniqueID) else {
      return
    }
    configurationDidChange()
  }

  /// Installs or retries the complete input-route observation.
  private func installRouteObservation() {
    guard routeObservation == nil else {
      return
    }
    do {
      routeObservation =
        try environment.observeInputRouteChanges {
          [weak self] in
          self?.configurationDidChange()
        }
      routeObservationFailure = nil
    } catch {
      routeObservationFailure = error.localizedDescription
    }
  }

  /// Refreshes Device listeners or reports the latest observation failure.
  private func refreshRouteObservation() throws {
    installRouteObservation()
    guard let routeObservation else {
      throw MicrophoneCaptureError.couldNotMonitorInput(
        routeObservationFailure
          ?? "Could not monitor microphone changes."
      )
    }
    do {
      try routeObservation.refresh()
      routeObservationFailure = nil
    } catch {
      routeObservationFailure = error.localizedDescription
      throw MicrophoneCaptureError.couldNotMonitorInput(
        error.localizedDescription
      )
    }
  }

  /// Primes resources for the current input route without capturing.
  func prepare() throws {
    for _ in 0..<Self.acquisitionAttemptLimit {
      let lease = try currentSession()
      try validateInput(of: lease.session)
      let configurationIsCurrent: Bool
      do {
        try lease.session.prepare()
        configurationIsCurrent =
          try configurationMatches(lease)
      } catch {
        discardSession()
        throw error
      }
      guard configurationIsCurrent else {
        discardSession()
        continue
      }
      return
    }
    throw MicrophoneCaptureError.inputConfigurationChanged
  }

  /// Starts capture only on a session matching the current route.
  func startCapture(
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
    onConfigurationChange:
      @escaping @Sendable () -> Void
  ) throws {
    for _ in 0..<Self.acquisitionAttemptLimit {
      let lease = try currentSession()
      try validateInput(of: lease.session)
      let didArm = eventState.withLock { state in
        guard state.generation == lease.generation else {
          return false
        }
        state.activeChangeHandler = onConfigurationChange
        return true
      }
      guard didArm else {
        discardSession()
        continue
      }

      do {
        try lease.session.startCapture(onBuffer: onBuffer)
        guard try configurationMatches(lease) else {
          throw MicrophoneCaptureError.inputConfigurationChanged
        }
        return
      } catch {
        let reportedError = failureAfterStart(
          error,
          lease: lease
        )
        eventState.withLock {
          $0.activeChangeHandler = nil
        }
        discardSession()
        throw reportedError
      }
    }
    throw MicrophoneCaptureError.inputConfigurationChanged
  }

  /// Stops capture while retaining unchanged prepared resources.
  func stop() {
    eventState.withLock {
      $0.activeChangeHandler = nil
    }
    guard
      let discardedSession = session,
      discardedSession.stop() == .discard
    else {
      return
    }
    retire(discardedSession)
    clearCurrentSession()
  }

  /// Returns an engine session aligned with the latest route generation.
  private func currentSession() throws -> SessionLease {
    try refreshRouteObservation()

    for _ in 0..<Self.acquisitionAttemptLimit {
      let route = try environment.currentInputRoute()
      let generation = eventState.withLock { $0.generation }
      if let session,
        sessionRoute == route,
        sessionGeneration == generation
      {
        return SessionLease(
          session: session,
          route: route,
          generation: generation
        )
      }

      discardSession()
      let replacement = try environment.makeEngine(
        for: route
      ) { [weak self] in
        self?.engineConfigurationChangeDisposition(
          expectedRoute: route,
          expectedGeneration: generation
        ) ?? .invalidate
      } onRecoveryFailure: { [weak self] in
        self?.invalidateEngineConfiguration(
          expectedGeneration: generation
        )
      }
      let routeAfterCreation: AudioInputRoute
      do {
        routeAfterCreation =
          try environment.currentInputRoute()
      } catch {
        _ = replacement.stop()
        retire(replacement)
        throw error
      }
      let generationAfterCreation = eventState.withLock {
        $0.generation
      }
      guard
        routeAfterCreation == route,
        generationAfterCreation == generation
      else {
        _ = replacement.stop()
        retire(replacement)
        continue
      }

      session = replacement
      sessionRoute = route
      sessionGeneration = generation
      return SessionLease(
        session: replacement,
        route: route,
        generation: generation
      )
    }
    throw MicrophoneCaptureError.inputConfigurationChanged
  }

  /// Rejects unavailable hardware before calling AVFAudio.
  private func validateInput(
    of session: any AudioEngineSession
  ) throws {
    guard
      let format = session.inputFormat,
      format.sampleRate > 0,
      format.channelCount > 0
    else {
      throw MicrophoneCaptureError.noInputDevice
    }
  }

  /// Confirms both route identity and generation around one system read.
  private func configurationMatches(
    _ lease: SessionLease
  ) throws -> Bool {
    let generationBefore = eventState.withLock {
      $0.generation
    }
    guard generationBefore == lease.generation else {
      return false
    }
    let route = try environment.currentInputRoute()
    let generationAfter = eventState.withLock {
      $0.generation
    }
    return route == lease.route
      && generationAfter == lease.generation
  }

  /// Recovers AVFAudio-only transitions while preserving route-change failure.
  private func engineConfigurationChangeDisposition(
    expectedRoute: AudioInputRoute,
    expectedGeneration: UInt64
  ) -> AudioEngineConfigurationChangeDisposition {
    let generationBefore = eventState.withLock {
      $0.generation
    }
    guard generationBefore == expectedGeneration else {
      return .invalidate
    }
    let currentRoute: AudioInputRoute
    do {
      currentRoute = try environment.currentInputRoute()
    } catch {
      invalidateEngineConfiguration(
        expectedGeneration: expectedGeneration
      )
      return .invalidate
    }
    let generationAfter = eventState.withLock {
      $0.generation
    }
    guard generationAfter == expectedGeneration else {
      return .invalidate
    }
    guard currentRoute == expectedRoute else {
      invalidateEngineConfiguration(
        expectedGeneration: expectedGeneration
      )
      return .invalidate
    }
    return .recover
  }

  /// Invalidates one engine unless a newer route event already won the race.
  private func invalidateEngineConfiguration(
    expectedGeneration: UInt64
  ) {
    let handler: (@Sendable () -> Void)? = eventState.withLock { state in
      guard state.generation == expectedGeneration else {
        return nil
      }
      state.generation &+= 1
      let handler = state.activeChangeHandler
      state.activeChangeHandler = nil
      return handler
    }
    handler?()
  }

  /// Converts a concurrent invalidation into the canonical route failure.
  private func failureAfterStart(
    _ error: any Error,
    lease: SessionLease
  ) -> any Error {
    do {
      guard try configurationMatches(lease) else {
        return MicrophoneCaptureError.inputConfigurationChanged
      }
    } catch {
      return error
    }
    return error
  }

  /// Stops and forgets an engine generation that cannot be reused safely.
  private func discardSession() {
    guard let discardedSession = session else {
      return
    }
    _ = discardedSession.stop()
    retire(discardedSession)
    clearCurrentSession()
  }

  /// Keeps AVFAudio alive until no route callback can race deallocation.
  private func retire(
    _ retiredSession: any AudioEngineSession
  ) {
    retiredSession.retire()
    retiredSessions.append(retiredSession)
  }

  /// Clears the current generation after its session has been retired.
  private func clearCurrentSession() {
    session = nil
    sessionRoute = nil
    sessionGeneration = nil
  }

  /// Invalidates prepared resources and fails active capture exactly once.
  private func configurationDidChange() {
    let handler = eventState.withLock { state in
      state.generation &+= 1
      let handler = state.activeChangeHandler
      state.activeChangeHandler = nil
      return handler
    }
    handler?()
  }
}

/// Reads the default input route and creates AVAudioEngine sessions.
final class SystemAudioEnvironment:
  AudioSystemEnvironment,
  @unchecked Sendable
{
  private let preferredDeviceUID: Mutex<String?>

  /// Creates an environment following one optional stable Device preference.
  init(preferredDeviceUID: String? = nil) {
    self.preferredDeviceUID = Mutex(preferredDeviceUID)
  }

  /// Returns every current Device with a usable input scope.
  func availableInputDevices() throws -> [AudioInputDevice] {
    try Self.audioDeviceIDs().compactMap { deviceID in
      guard try Self.inputChannelCount(for: deviceID) > 0 else {
        return nil
      }
      let device = AudioInputDevice(
        uniqueID: try Self.deviceUID(for: deviceID),
        name: try Self.deviceName(for: deviceID)
      )
      return device.isStableSelection ? device : nil
    }
    .sorted {
      let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
      return comparison == .orderedSame
        ? $0.uniqueID < $1.uniqueID
        : comparison == .orderedAscending
    }
  }

  /// Updates the stable preference without changing the system-wide default.
  func setPreferredInputDeviceUID(_ uniqueID: String?) -> Bool {
    preferredDeviceUID.withLock { current in
      guard current != uniqueID else {
        return false
      }
      current = uniqueID
      return true
    }
  }

  /// Returns the preferred input when present, otherwise the system default.
  func currentInputRoute() throws -> AudioInputRoute {
    let deviceID = try effectiveInputDeviceID()
    let sampleRate = try Self.nominalSampleRate(
      for: deviceID
    )
    let channelCount = try Self.inputChannelCount(
      for: deviceID
    )
    guard
      deviceID != kAudioObjectUnknown,
      sampleRate > 0,
      channelCount > 0
    else {
      throw MicrophoneCaptureError.noInputDevice
    }
    return AudioInputRoute(
      deviceID: deviceID,
      sampleRate: sampleRate,
      channelCount: channelCount
    )
  }

  /// Creates one AVAudioEngine generation pinned to the acquired Device.
  func makeEngine(
    for route: AudioInputRoute,
    onConfigurationChange:
      @escaping @Sendable () -> AudioEngineConfigurationChangeDisposition,
    onRecoveryFailure:
      @escaping @Sendable () -> Void
  ) throws -> any AudioEngineSession {
    let preferredUID = preferredDeviceUID.withLock { $0 }
    return try SystemAudioEngineSession(
      deviceID: Self.pinnedDeviceID(
        for: route,
        preferredDeviceUID: preferredUID
      ),
      onConfigurationChange: onConfigurationChange,
      onRecoveryFailure: onRecoveryFailure
    )
  }

  /// Pins only an explicit app-local selection; System Default stays negotiated.
  static func pinnedDeviceID(
    for route: AudioInputRoute,
    preferredDeviceUID: String?
  ) -> AudioDeviceID? {
    preferredDeviceUID == nil ? nil : route.deviceID
  }

  /// Observes every input identity or format change.
  func observeInputRouteChanges(
    _ handler: @escaping @Sendable () -> Void
  ) throws -> any AudioInputRouteObservation {
    try CoreAudioInputRouteObservation(
      inputDeviceID: { [weak self] in
        guard let self else {
          throw MicrophoneCaptureError.noInputDevice
        }
        return try self.effectiveInputDeviceID()
      },
      handler: handler
    )
  }

  /// Resolves a saved UID when connected and otherwise follows the default.
  private func effectiveInputDeviceID() throws -> AudioDeviceID {
    let preferredUID = preferredDeviceUID.withLock { $0 }
    if let preferredUID,
      let preferredDeviceID = try Self.audioDeviceIDs().first(where: {
        try Self.deviceUID(for: $0) == preferredUID
          && Self.inputChannelCount(for: $0) > 0
      })
    {
      return preferredDeviceID
    }
    return try Self.defaultInputDeviceID()
  }

  /// Reads every current CoreAudio Device object.
  private static func audioDeviceIDs() throws -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32.zero
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size
    )
    try requireSuccess(status, operation: "size the audio Device list")
    guard size.isMultiple(of: UInt32(MemoryLayout<AudioDeviceID>.size)) else {
      throw MicrophoneCaptureError.couldNotMonitorInput(
        "The audio Device list has an invalid size."
      )
    }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else {
      return []
    }
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: MemoryLayout<AudioDeviceID>.alignment
    )
    defer {
      storage.deallocate()
    }
    status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      storage
    )
    try requireSuccess(status, operation: "read the audio Device list")
    let deviceIDs = storage.bindMemory(
      to: AudioDeviceID.self,
      capacity: count
    )
    return Array(
      UnsafeBufferPointer(start: deviceIDs, count: count)
    )
  }

  /// Reads one Device's persistent CoreAudio UID.
  private static func deviceUID(for deviceID: AudioDeviceID) throws -> String {
    try stringProperty(
      kAudioDevicePropertyDeviceUID,
      for: deviceID,
      operation: "read the microphone identifier"
    )
  }

  /// Reads one Device's user-facing CoreAudio name.
  private static func deviceName(for deviceID: AudioDeviceID) throws -> String {
    try stringProperty(
      kAudioObjectPropertyName,
      for: deviceID,
      operation: "read the microphone name"
    )
  }

  /// Reads one nonempty CoreAudio string property.
  private static func stringProperty(
    _ selector: AudioObjectPropertySelector,
    for deviceID: AudioDeviceID,
    operation: String
  ) throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &value
    )
    try requireSuccess(status, operation: operation)
    guard let value else {
      throw MicrophoneCaptureError.couldNotMonitorInput(
        "Could not \(operation)."
      )
    }
    let result = value.takeRetainedValue() as String
    guard !result.isEmpty else {
      throw MicrophoneCaptureError.couldNotMonitorInput(
        "Could not \(operation)."
      )
    }
    return result
  }

  /// Reads the system's current default input Device.
  fileprivate static func defaultInputDeviceID() throws
    -> AudioDeviceID
  {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )
    try requireSuccess(
      status,
      operation: "read the default microphone"
    )
    return deviceID
  }

  /// Reads one Device's nominal sample rate.
  private static func nominalSampleRate(
    for deviceID: AudioDeviceID
  ) throws -> Float64 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var sampleRate = Float64.zero
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &sampleRate
    )
    try requireSuccess(
      status,
      operation: "read the microphone sample rate"
    )
    return sampleRate
  }

  /// Counts the Device's current input channels.
  private static func inputChannelCount(
    for deviceID: AudioDeviceID
  ) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32.zero
    var status = AudioObjectGetPropertyDataSize(
      deviceID,
      &address,
      0,
      nil,
      &size
    )
    try requireSuccess(
      status,
      operation: "size the microphone channel list"
    )
    guard size >= MemoryLayout<UInt32>.size else {
      throw MicrophoneCaptureError.couldNotMonitorInput(
        "The microphone channel list has an invalid size."
      )
    }

    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: max(Int(size), MemoryLayout<AudioBufferList>.size),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer {
      storage.deallocate()
    }
    let list = storage.bindMemory(
      to: AudioBufferList.self,
      capacity: 1
    )
    status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      list
    )
    try requireSuccess(
      status,
      operation: "read the microphone channel list"
    )
    return UnsafeMutableAudioBufferListPointer(list)
      .reduce(UInt32.zero) {
        $0 + $1.mNumberChannels
      }
  }

  /// Converts CoreAudio status codes into typed capture failures.
  private static func requireSuccess(
    _ status: OSStatus,
    operation: String
  ) throws {
    guard status == noErr else {
      throw MicrophoneCaptureError.couldNotMonitorInput(
        "Could not \(operation) (\(status))."
      )
    }
  }
}

/// Observes available, effective, sample-rate, and input-stream changes.
private final class CoreAudioInputRouteObservation:
  AudioInputRouteObservation,
  @unchecked Sendable
{
  private let queue = DispatchQueue(
    label:
      "\(ApplicationIdentity.bundleIdentifier).audio_input_route"
  )
  private let state: CoreAudioInputObservationState
  private let defaultDeviceObservation: CoreAudioPropertyObservation
  private let availableDevicesObservation: CoreAudioPropertyObservation

  /// Registers route listeners on one private serial queue.
  init(
    inputDeviceID: @escaping @Sendable () throws -> AudioDeviceID,
    handler: @escaping @Sendable () -> Void
  ) throws {
    state = CoreAudioInputObservationState(
      queue: queue,
      inputDeviceID: inputDeviceID,
      handler: handler
    )
    defaultDeviceObservation =
      try CoreAudioPropertyObservation(
        AudioObjectID(kAudioObjectSystemObject),
        address: AudioObjectPropertyAddress(
          mSelector:
            kAudioHardwarePropertyDefaultInputDevice,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        ),
        queue: queue
      ) { [state] in
        state.routeSourceDidChange()
      }
    availableDevicesObservation =
      try CoreAudioPropertyObservation(
        AudioObjectID(kAudioObjectSystemObject),
        address: AudioObjectPropertyAddress(
          mSelector: kAudioHardwarePropertyDevices,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        ),
        queue: queue
      ) { [state] in
        state.routeSourceDidChange()
      }
    try state.rebindDeviceObservation()
  }

  /// Rebinds Device listeners after any transient CoreAudio failure.
  func refresh() throws {
    try state.rebindDeviceObservation()
  }
}

/// Rebinds property listeners whenever the effective Device changes.
private final class CoreAudioInputObservationState:
  @unchecked Sendable
{
  private struct DeviceState {
    var deviceID: AudioDeviceID?
    var observation: CoreAudioDeviceInputObservation?
  }

  private let queue: DispatchQueue
  private let inputDeviceID: @Sendable () throws -> AudioDeviceID
  private let handler: @Sendable () -> Void
  private let deviceState = Mutex(DeviceState())
  private let logger = Logger(
    subsystem: ApplicationIdentity.bundleIdentifier,
    category: "microphone"
  )

  /// Retains the callback and queue used by every Device generation.
  init(
    queue: DispatchQueue,
    inputDeviceID: @escaping @Sendable () throws -> AudioDeviceID,
    handler: @escaping @Sendable () -> Void
  ) {
    self.queue = queue
    self.inputDeviceID = inputDeviceID
    self.handler = handler
  }

  /// Installs listeners for the current effective Device's full input shape.
  @discardableResult
  func rebindDeviceObservation() throws -> Bool {
    let deviceID = try inputDeviceID()
    guard deviceID != kAudioObjectUnknown else {
      throw MicrophoneCaptureError.noInputDevice
    }
    let alreadyObserving = deviceState.withLock {
      $0.deviceID == deviceID
        && $0.observation != nil
    }
    guard !alreadyObserving else {
      return false
    }
    let replacement = try CoreAudioDeviceInputObservation(
      deviceID: deviceID,
      queue: queue,
      handler: handler
    )
    let previous = deviceState.withLock {
      let previous = $0.observation
      $0.deviceID = deviceID
      $0.observation = replacement
      return previous
    }
    withExtendedLifetime(previous) {}
    return true
  }

  /// Rebinds first, then invalidates consumers of the previous Device.
  func routeSourceDidChange() {
    let effectiveDeviceChanged: Bool
    do {
      effectiveDeviceChanged = try rebindDeviceObservation()
    } catch {
      logger.error(
        "Microphone observation rebind failed: \(error.localizedDescription, privacy: .public)"
      )
      handler()
      return
    }
    guard effectiveDeviceChanged else {
      return
    }
    handler()
  }
}

/// Owns listeners for one Device's rate and input-channel shape.
private final class CoreAudioDeviceInputObservation:
  @unchecked Sendable
{
  private let sampleRateObservation: CoreAudioPropertyObservation
  private let streamConfigurationObservation: CoreAudioPropertyObservation

  /// Registers both properties that determine the input format.
  init(
    deviceID: AudioDeviceID,
    queue: DispatchQueue,
    handler: @escaping @Sendable () -> Void
  ) throws {
    sampleRateObservation =
      try CoreAudioPropertyObservation(
        deviceID,
        address: AudioObjectPropertyAddress(
          mSelector:
            kAudioDevicePropertyNominalSampleRate,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        ),
        queue: queue,
        handler: handler
      )
    streamConfigurationObservation =
      try CoreAudioPropertyObservation(
        deviceID,
        address: AudioObjectPropertyAddress(
          mSelector:
            kAudioDevicePropertyStreamConfiguration,
          mScope: kAudioDevicePropertyScopeInput,
          mElement: kAudioObjectPropertyElementMain
        ),
        queue: queue,
        handler: handler
      )
  }
}

/// Registers and removes one CoreAudio block listener exactly once.
private final class CoreAudioPropertyObservation:
  @unchecked Sendable
{
  private let objectID: AudioObjectID
  private let address: AudioObjectPropertyAddress
  private let queue: DispatchQueue
  private let listener: AudioObjectPropertyListenerBlock

  /// Registers a callback for one concrete CoreAudio property.
  init(
    _ objectID: AudioObjectID,
    address: AudioObjectPropertyAddress,
    queue: DispatchQueue,
    handler: @escaping @Sendable () -> Void
  ) throws {
    self.objectID = objectID
    self.address = address
    self.queue = queue
    listener = { _, _ in
      handler()
    }
    var address = address
    let status = AudioObjectAddPropertyListenerBlock(
      objectID,
      &address,
      queue,
      listener
    )
    guard status == noErr else {
      throw MicrophoneCaptureError.couldNotMonitorInput(
        "Could not monitor microphone changes (\(status))."
      )
    }
  }

  deinit {
    var address = address
    let status = AudioObjectRemovePropertyListenerBlock(
      objectID,
      &address,
      queue,
      listener
    )
    if status != noErr {
      let logger = Logger(
        subsystem: ApplicationIdentity.bundleIdentifier,
        category: "microphone"
      )
      logger.error(
        "Microphone observer cleanup failed: \(status, privacy: .public)"
      )
    }
  }
}

/// Owns one AVAudioEngine and one exception-prone input tap.
private final class SystemAudioEngineSession:
  AudioEngineSession,
  @unchecked Sendable
{
  private let engine = AVAudioEngine()
  private let operationQueue = DispatchQueue(
    label: "\(ApplicationIdentity.bundleIdentifier).audio_engine"
  )
  private let logger = Logger(
    subsystem: ApplicationIdentity.bundleIdentifier,
    category: "microphone"
  )
  private let configurationChangeDisposition:
    @Sendable () -> AudioEngineConfigurationChangeDisposition
  private let onRecoveryFailure: @Sendable () -> Void
  private var configurationObservation: NSObjectProtocol?
  private var hasTap = false
  private var isCapturing = false
  private var recoveryAttemptCount = 0
  private static let recoveryAttemptLimit = 1

  /// Creates an engine and observes its private I/O configuration.
  init(
    deviceID: AudioDeviceID?,
    onConfigurationChange:
      @escaping @Sendable () -> AudioEngineConfigurationChangeDisposition,
    onRecoveryFailure:
      @escaping @Sendable () -> Void
  ) throws {
    configurationChangeDisposition = onConfigurationChange
    self.onRecoveryFailure = onRecoveryFailure
    if var deviceID {
      let inputNode = engine.inputNode
      guard let audioUnit = inputNode.audioUnit else {
        throw MicrophoneCaptureError.couldNotStart(
          "The selected microphone has no audio unit."
        )
      }
      let status = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &deviceID,
        UInt32(MemoryLayout<AudioDeviceID>.size)
      )
      guard status == noErr else {
        throw MicrophoneCaptureError.couldNotStart(
          "The selected microphone could not be opened (\(status))."
        )
      }
    }
    configurationObservation =
      NotificationCenter.default.addObserver(
        forName:
          .AVAudioEngineConfigurationChange,
        object: engine,
        queue: nil
      ) { [weak self] _ in
        self?.scheduleConfigurationRecovery()
      }
  }

  deinit {
    if let configurationObservation {
      NotificationCenter.default.removeObserver(
        configurationObservation
      )
    }
  }

  var inputFormat: AVAudioFormat? {
    operationQueue.sync {
      let format = engine.inputNode.inputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        return nil
      }
      return format
    }
  }

  /// Primes current graph resources.
  func prepare() throws {
    try operationQueue.sync {
      try prepareEngine()
    }
  }

  /// Prepares the engine while preserving typed boundary failures.
  private func prepareEngine() throws {
    do {
      try HCAudioEngineExceptionBoundary.prepare(engine)
    } catch {
      logger.error(
        "Microphone preparation failed: \(error.localizedDescription, privacy: .public)"
      )
      throw MicrophoneCaptureError.couldNotStart(
        "The current microphone input could not be prepared."
      )
    }
  }

  /// Uses framework-negotiated tap format for the current input.
  func startCapture(
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) throws {
    try operationQueue.sync {
      guard stopEngine() == .reusable else {
        throw MicrophoneCaptureError.couldNotStart(
          "The previous microphone input could not be closed."
        )
      }
      do {
        try HCAudioEngineExceptionBoundary.installTap(
          on: engine.inputNode,
          bus: 0,
          bufferSize: 1_024,
          format: nil
        ) { buffer, _ in
          onBuffer(buffer)
        }
        hasTap = true
        try HCAudioEngineExceptionBoundary.prepare(engine)
        try HCAudioEngineExceptionBoundary.start(engine)
        recoveryAttemptCount = 0
        isCapturing = true
      } catch {
        _ = stopEngine()
        logger.error(
          "Microphone start failed: \(error.localizedDescription, privacy: .public)"
        )
        throw MicrophoneCaptureError.couldNotStart(
          "The current microphone input could not be opened."
        )
      }
    }
  }

  /// Stops graph work and removes the owned tap once.
  func stop() -> AudioEngineStopResult {
    operationQueue.sync {
      stopEngine()
    }
  }

  /// Stops serialized graph work and removes the owned tap once.
  private func stopEngine() -> AudioEngineStopResult {
    isCapturing = false
    recoveryAttemptCount = 0
    var result = AudioEngineStopResult.reusable
    do {
      try HCAudioEngineExceptionBoundary.stop(engine)
    } catch {
      logger.error(
        "Microphone engine stop failed: \(error.localizedDescription, privacy: .public)"
      )
      result = .discard
    }
    guard hasTap else {
      return result
    }
    do {
      try HCAudioEngineExceptionBoundary.removeTap(
        from: engine.inputNode,
        bus: 0
      )
      hasTap = false
      return result
    } catch {
      logger.error(
        "Microphone cleanup failed: \(error.localizedDescription, privacy: .public)"
      )
      return .discard
    }
  }

  /// Stops private notifications while retaining the inert AVAudioEngine.
  func retire() {
    operationQueue.sync {
      isCapturing = false
      if let configurationObservation {
        NotificationCenter.default.removeObserver(
          configurationObservation
        )
        self.configurationObservation = nil
      }
    }
  }

  /// Moves recovery away from AVFAudio's internal notification queue.
  private func scheduleConfigurationRecovery() {
    operationQueue.async { [weak self] in
      self?.recoverFromConfigurationChange()
    }
  }

  /// Restarts one unchanged graph transition or invalidates bounded failure.
  private func recoverFromConfigurationChange() {
    guard isCapturing else {
      return
    }
    guard configurationChangeDisposition() == .recover else {
      isCapturing = false
      return
    }
    guard recoveryAttemptCount < Self.recoveryAttemptLimit else {
      failRecovery()
      return
    }
    recoveryAttemptCount += 1
    do {
      try HCAudioEngineExceptionBoundary.prepare(engine)
      try HCAudioEngineExceptionBoundary.start(engine)
    } catch {
      logger.error(
        "Microphone configuration recovery failed: \(error.localizedDescription, privacy: .public)"
      )
      failRecovery()
    }
  }

  /// Fails the active stream after recovery cannot restore the graph.
  private func failRecovery() {
    isCapturing = false
    onRecoveryFailure()
  }
}
