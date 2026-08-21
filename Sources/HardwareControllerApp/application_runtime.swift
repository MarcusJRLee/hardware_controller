import Foundation
import HardwareControllerCore
import HardwareControllerMac
import ServiceManagement

typealias LiveActionExecutor = MacActionExecutor<
  CoreGraphicsKeyboardEventPoster
>
typealias LiveControllerRuntime = ControllerRuntime<LiveActionExecutor>

/// Isolates Profile persistence from application orchestration.
protocol ProfilePersisting: Sendable {
  /// Loads the current Profile envelope and any recoverable issue.
  func load() -> ProfileLoadResult

  /// Persists one validated Profile envelope atomically.
  func save(_ envelope: ProfileEnvelope) throws
}

extension ProfileStore: ProfilePersisting {}

/// Keeps deterministic previews isolated from the user's persisted Profile.
private struct PreviewProfileStore: ProfilePersisting {
  /// Returns the preview's fixed default configuration.
  func load() -> ProfileLoadResult {
    ProfileLoadResult(
      envelope: .defaultEnvelope(),
      issue: nil
    )
  }

  /// Accepts preview-only edits without writing outside the process.
  func save(_ envelope: ProfileEnvelope) throws {}
}

/// Contains all non-presentation state published by the application runtime.
struct ApplicationSnapshot: Equatable, Sendable {
  var envelope: ProfileEnvelope
  var runtime = RuntimeSnapshot(
    devices: [],
    lastDispatchLatencyNanoseconds: nil,
    lastActionDispatchSucceeded: nil
  )
  var accessibilityTrusted: Bool
  var microphonePermission: PermissionStatus
  var speechRecognitionPermission: PermissionStatus
  var transcription: TranscriptionSnapshot
  var localAIDictation: LocalAIDictationSnapshot = .idle
  var localAIReadiness: LocalAIReadinessSnapshot = .checking
  var localAIProvider: LocalAIProviderKind = .appleOnDevice
  var localAIProviderTest: LocalAIProviderTestState = .idle
  var transcriptionPrepared = false
  var transcriptionPreparationFailure: TranscriptionFailure?
  var launchAtLogin: Bool
  var hardwareInputFailure: HardwareInputStartFailure?
  var keyboardFallbackFailures: [KeyboardFallbackRegistrationFailure] = []
  var lastError: String?
  var recoveryNotice: String?
}

/// Describes the system state that controls Action availability.
struct ApplicationSystemState: Equatable, Sendable {
  let accessibilityTrusted: Bool
  let microphonePermission: PermissionStatus
  let speechRecognitionPermission: PermissionStatus
  let launchAtLogin: Bool
}

/// Identifies one permission request without leaking system frameworks.
enum ApplicationPermission: Sendable {
  case accessibility
  case microphone
  case speechRecognition
}

/// Isolates permission prompts and login-item registration on the main actor.
protocol ApplicationSystemControlling: Sendable {
  /// Returns authoritative permission and login-item state.
  @MainActor func currentState() -> ApplicationSystemState

  /// Requests one permission and returns refreshed system state.
  @MainActor func request(
    _ permission: ApplicationPermission
  ) async -> ApplicationSystemState

  /// Changes login-item registration and returns refreshed system state.
  @MainActor func setLaunchAtLogin(
    _ enabled: Bool
  ) throws -> ApplicationSystemState
}

/// Uses the actual macOS permission and login-item facilities.
@MainActor
final class SystemApplicationController:
  ApplicationSystemControlling
{
  private var stateOverride: ApplicationSystemState?

  /// Creates a live adapter, optionally with deterministic demo state.
  init(stateOverride: ApplicationSystemState? = nil) {
    self.stateOverride = stateOverride
  }

  /// Reads current permissions and login-item registration.
  func currentState() -> ApplicationSystemState {
    if let stateOverride {
      return stateOverride
    }
    return ApplicationSystemState(
      accessibilityTrusted: AccessibilityPermission.isTrusted,
      microphonePermission: MicrophonePermission.status,
      speechRecognitionPermission:
        LegacySpeechPermission.isRequired
        ? LegacySpeechPermission.status : .authorized,
      launchAtLogin: SMAppService.mainApp.status == .enabled
    )
  }

  /// Requests one permission and returns a complete refreshed state.
  func request(
    _ permission: ApplicationPermission
  ) async -> ApplicationSystemState {
    guard stateOverride == nil else {
      return currentState()
    }

    switch permission {
    case .accessibility:
      _ = AccessibilityPermission.request()
    case .microphone:
      _ = await MicrophonePermission.request()
    case .speechRecognition:
      _ = await LegacySpeechPermission.request()
    }
    return currentState()
  }

  /// Changes login-item registration and returns authoritative state.
  func setLaunchAtLogin(
    _ enabled: Bool
  ) throws -> ApplicationSystemState {
    if let current = stateOverride {
      let updated = ApplicationSystemState(
        accessibilityTrusted: current.accessibilityTrusted,
        microphonePermission: current.microphonePermission,
        speechRecognitionPermission:
          current.speechRecognitionPermission,
        launchAtLogin: enabled
      )
      stateOverride = updated
      return updated
    }

    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
    return currentState()
  }
}

/// Defines the process work hidden behind application orchestration.
protocol ApplicationProcessControlling: Sendable {
  var deviceDescriptor: DeviceModelDescriptor { get }

  /// Starts hardware input or deterministic preview input.
  func start() async -> HardwareInputStartResult

  /// Stops and releases every process resource.
  func stop() async

  /// Ends active work while preserving restartable resources.
  func suspend() async

  /// Restarts hardware input after suspension.
  func resume() async -> HardwareInputStartResult

  /// Retries only hardware-input discovery.
  func retryHardwareInput() -> HardwareInputStartResult

  /// Replaces the active process Profile.
  func setProfile(_ profile: Profile) async

  /// Applies permission-derived Action availability.
  func setAvailability(_ availability: ActionExecutionAvailability)

  /// Prepares local transcription without capturing audio.
  func warmUpTranscription() async -> TranscriptionFailure?

  /// Cancels Dictation and changes this app's preferred microphone.
  func setPreferredMicrophoneUID(_ uniqueID: String?) async

  /// Reconfigures Local AI Dictation and returns provider readiness.
  func setLocalAISettings(
    _ settings: LocalAISettings,
    profileName: String
  ) async -> LocalAIReadinessSnapshot

  /// Returns current local provider and model readiness.
  func localAIReadiness() async -> LocalAIReadinessSnapshot

  /// Runs a sanitized generation test without microphone or target access.
  func testLocalAIProvider() async -> LocalAIRefinementFailure?

  /// Runs one configured Binding without physical input.
  func testBinding(_ controlID: ControlID)

  /// Sends one preview-only Control transition.
  func simulate(_ controlID: ControlID, phase: ControlPhase)
}

/// Carries process events through lock-protected state without blocking producers.
final class ApplicationProcessEventRelay:
  @unchecked Sendable
{
  enum Event: Sendable {
    case runtime(RuntimeSnapshot)
    case transcription(TranscriptionSnapshot)
    case localAIDictation(LocalAIDictationSnapshot)
    case keyboardFallbackFailures(
      [KeyboardFallbackRegistrationFailure]
    )
  }

  typealias Handler = @Sendable (Event) -> Void

  private let lock = NSLock()
  private var handler: Handler?
  private weak var runtime: LiveControllerRuntime?
  private var latestRuntimeSnapshot = RuntimeSnapshot(
    devices: [],
    lastDispatchLatencyNanoseconds: nil,
    lastActionDispatchSucceeded: nil
  )

  /// Installs the runtime after its cyclic transcription dependency exists.
  func installRuntime(_ runtime: LiveControllerRuntime) {
    lock.withLock {
      self.runtime = runtime
    }
  }

  /// Installs the actor event handler before process work starts.
  func installHandler(_ handler: @escaping Handler) {
    lock.withLock {
      self.handler = handler
    }
  }

  /// Publishes a hot-path snapshot without waiting on application state.
  func publishRuntime(_ snapshot: RuntimeSnapshot) {
    let handler = lock.withLock {
      latestRuntimeSnapshot = snapshot
      return self.handler
    }
    handler?(.runtime(snapshot))
  }

  /// Resolves a connected Device that exposes the requested Control.
  func deviceID(for controlID: ControlID) -> DeviceID? {
    lock.withLock {
      latestRuntimeSnapshot.devices.first {
        $0.model.controls.contains { $0.id == controlID }
      }?.id
    }
  }

  /// Publishes transcription and reconciles failed Dictation ownership.
  func publishTranscription(_ snapshot: TranscriptionSnapshot) {
    let values = lock.withLock {
      (runtime, handler)
    }
    if snapshot.phase == .failed {
      values.0?.actionDidFail(.dictation)
    }
    values.1?(.transcription(snapshot))
  }

  /// Publishes Local AI progress and reconciles failed Action ownership.
  func publishLocalAIDictation(_ snapshot: LocalAIDictationSnapshot) {
    let values = lock.withLock {
      (runtime, handler)
    }
    if snapshot.phase == .failed {
      values.0?.actionDidFail(.localAIDictation)
    }
    values.1?(.localAIDictation(snapshot))
  }

  /// Publishes exact-shortcut reservation failures outside the input hot path.
  func publishKeyboardFallbackFailures(
    _ failures: [KeyboardFallbackRegistrationFailure]
  ) {
    let handler = lock.withLock { self.handler }
    handler?(.keyboardFallbackFailures(failures))
  }
}

/// Owns queue- or actor-isolated process seams behind a Sendable interface.
private final class LiveApplicationProcess:
  ApplicationProcessControlling,
  @unchecked Sendable
{
  let deviceDescriptor = Infinity3Driver.descriptor

  private let isDemoMode: Bool
  private let showsDemoPressedState: Bool
  private let runtime: LiveControllerRuntime
  private let inputSource: any HardwareInputSource
  private let transcriptionController: OwnedTranscriptionController
  private let localAIDictationController: LocalAIDictationController
  private let dictationDispatcher: any DictationCommandDispatching
  private let eventRelay: ApplicationProcessEventRelay
  private var profile: Profile
  private var localAISettings: LocalAISettings
  private var keyboardFallbackInputSource: KeyboardFallbackInputSource?
  private var isRunning = false

  /// Composes all live adapters while keeping their details behind one interface.
  init(
    profile: Profile,
    isDemoMode: Bool,
    showsDemoPressedState: Bool,
    preferredMicrophoneUID: String?,
    localAISettings: LocalAISettings,
    eventRelay: ApplicationProcessEventRelay
  ) {
    self.isDemoMode = isDemoMode
    self.showsDemoPressedState = showsDemoPressedState
    self.eventRelay = eventRelay
    self.profile = profile
    self.localAISettings = localAISettings

    let inputQueue = DispatchQueue(
      label: "\(ApplicationIdentity.bundleIdentifier).input",
      qos: .userInteractive
    )
    let targeter = AccessibilityFocusedTextTargeting()
    let writer = SafeTranscriptWriter(
      targeter: targeter,
      inserter: AdaptiveFocusedTextInserter()
    )
    let sessionFactory = AppleSpeechRecognitionSessionFactory()
    let microphone = AVAudioEngineMicrophoneCapture(
      preferredInputDeviceUID: preferredMicrophoneUID
    )
    let transcriptionController = OwnedTranscriptionController(
      factory: sessionFactory,
      microphone: microphone,
      targeter: targeter,
      writer: writer,
      authorization:
        SystemTranscriptionAuthorizationProvider(),
      snapshotHandler: eventRelay.publishTranscription
    )
    self.transcriptionController = transcriptionController

    let localAIDictationController = LocalAIDictationController(
      factory: sessionFactory,
      microphone: microphone,
      targeter: targeter,
      writer: writer,
      authorization: SystemTranscriptionAuthorizationProvider(),
      settings: localAISettings,
      profileName: profile.name,
      snapshotHandler: eventRelay.publishLocalAIDictation
    )
    self.localAIDictationController = localAIDictationController

    let localDispatcher: any DictationCommandDispatching
    let localAIDispatcher: any DictationCommandDispatching
    if isDemoMode {
      localDispatcher = PreviewDictationCommandDispatcher()
      localAIDispatcher = PreviewDictationCommandDispatcher()
    } else {
      let dispatchers = CoordinatedDictationDispatchers(
        localHandler: { [transcriptionController] command in
          await transcriptionController.handle(command)
        },
        localAIHandler: { [localAIDictationController] command in
          await localAIDictationController.handle(command)
        },
        onShutdown: {
          await transcriptionController.shutdown()
          await localAIDictationController.shutdown()
        }
      )
      localDispatcher = dispatchers.local
      localAIDispatcher = dispatchers.localAI
    }
    dictationDispatcher = localDispatcher

    let runtime = LiveControllerRuntime(
      queue: inputQueue,
      profile: profile,
      executor: LiveActionExecutor(
        poster: CoreGraphicsKeyboardEventPoster(),
        dictation: localDispatcher,
        localAIDictation: localAIDispatcher
      ),
      onSnapshot: eventRelay.publishRuntime
    )
    self.runtime = runtime
    eventRelay.installRuntime(runtime)

    inputSource = InfinityHIDManager(
      queue: inputQueue,
      onConnect: { [weak runtime] connection in
        runtime?.connect(connection)
      },
      onDisconnect: { [weak runtime] deviceID in
        runtime?.disconnect(deviceID: deviceID)
      },
      onEvent: { [weak runtime] event in
        runtime?.handle(event)
      }
    )
  }

  /// Starts live input or installs the deterministic demo Device.
  func start() async -> HardwareInputStartResult {
    isRunning = true
    await registerKeyboardFallbacks()
    if isDemoMode {
      runtime.connect(
        HardwareDeviceConnection(
          id: Self.demoDeviceID,
          name: "\(deviceDescriptor.name) · Demo",
          model: deviceDescriptor
        )
      )
      if showsDemoPressedState,
        let controlID = deviceDescriptor.controls
          .first(where: { $0.visualWeight == .prominent })?.id
          ?? deviceDescriptor.controls.first?.id
      {
        runtime.handle(
          ControlEvent(
            deviceID: Self.demoDeviceID,
            controlID: controlID,
            phase: .pressed,
            timestampNanoseconds:
              MonotonicClock.nowNanoseconds()
          )
        )
      }
      return .started
    }
    return inputSource.start()
  }

  /// Stops every owned process seam and waits for transcription cleanup.
  func stop() async {
    isRunning = false
    await stopKeyboardFallbacks()
    inputSource.stop()
    runtime.shutdown()
    await dictationDispatcher.shutdownAndWait()
    if isDemoMode {
      await transcriptionController.shutdown()
      await localAIDictationController.shutdown()
    }
  }

  /// Ends active work for sleep while preserving restartable process resources.
  func suspend() async {
    isRunning = false
    await stopKeyboardFallbacks()
    inputSource.stop()
    runtime.suspend()
    await transcriptionController.handle(.cancel)
    await localAIDictationController.handle(.cancel)
  }

  /// Restarts hardware input after wake.
  func resume() async -> HardwareInputStartResult {
    isRunning = true
    await registerKeyboardFallbacks()
    guard !isDemoMode else {
      return .started
    }
    return inputSource.start()
  }

  /// Restarts only the hardware-input adapter.
  func retryHardwareInput() -> HardwareInputStartResult {
    guard !isDemoMode else {
      return .started
    }
    inputSource.stop()
    return inputSource.start()
  }

  /// Replaces the active Profile on the serialized Action runtime.
  func setProfile(_ profile: Profile) async {
    await runtime.setProfile(profile)
    self.profile = profile
    await localAIDictationController.update(
      settings: localAISettings,
      profileName: profile.name
    )
    if isRunning {
      await registerKeyboardFallbacks()
    }
  }

  /// Applies current permission-derived Action availability.
  func setAvailability(_ availability: ActionExecutionAvailability) {
    runtime.setActionExecutionAvailability(availability)
  }

  /// Prepares recognition assets and audio format without capturing audio.
  func warmUpTranscription() async -> TranscriptionFailure? {
    if isDemoMode {
      return nil
    }
    return await transcriptionController.warmUp()
  }

  /// Ends any owned session before changing the app-local input route.
  func setPreferredMicrophoneUID(_ uniqueID: String?) async {
    guard !isDemoMode else {
      return
    }
    runtime.actionDidFail(.dictation)
    runtime.actionDidFail(.localAIDictation)
    await localAIDictationController.handle(.cancel)
    await transcriptionController.selectInputDevice(
      uniqueID: uniqueID
    )
  }

  /// Applies Local AI settings after canceling any active AI session.
  func setLocalAISettings(
    _ settings: LocalAISettings,
    profileName: String
  ) async -> LocalAIReadinessSnapshot {
    localAISettings = settings
    if isDemoMode {
      return Self.demoLocalAIReadiness
    }
    await localAIDictationController.update(
      settings: settings,
      profileName: profileName
    )
    return await localAIDictationController.readiness()
  }

  /// Reports both local provider states without loading either model.
  func localAIReadiness() async -> LocalAIReadinessSnapshot {
    if isDemoMode {
      return Self.demoLocalAIReadiness
    }
    return await localAIDictationController.readiness()
  }

  /// Tests only the selected provider with fixed non-user content.
  func testLocalAIProvider() async -> LocalAIRefinementFailure? {
    guard !isDemoMode else {
      return nil
    }
    return await localAIDictationController.testProvider()
  }

  private static let demoLocalAIReadiness = LocalAIReadinessSnapshot(
    apple: LocalAIProviderReadiness(
      provider: .appleOnDevice,
      state: .ready
    ),
    ollama: LocalAIProviderReadiness(
      provider: .ollama,
      state: .unavailable("Ollama is not queried in Demo Mode.")
    )
  )

  /// Runs one complete synthetic press and release through the Action runtime.
  func testBinding(_ controlID: ControlID) {
    let deviceID =
      eventRelay.deviceID(for: controlID)
      ?? Self.demoDeviceID
    runtime.handle(
      ControlEvent(
        deviceID: deviceID,
        controlID: controlID,
        phase: .pressed,
        timestampNanoseconds: MonotonicClock.nowNanoseconds()
      )
    )
    Task { [weak runtime] in
      try? await Task.sleep(for: .milliseconds(650))
      runtime?.handle(
        ControlEvent(
          deviceID: deviceID,
          controlID: controlID,
          phase: .released,
          timestampNanoseconds: MonotonicClock.nowNanoseconds()
        )
      )
    }
  }

  /// Sends one demo-only Control transition through the Action runtime.
  func simulate(_ controlID: ControlID, phase: ControlPhase) {
    guard isDemoMode else {
      return
    }
    runtime.handle(
      ControlEvent(
        deviceID: Self.demoDeviceID,
        controlID: controlID,
        phase: phase,
        timestampNanoseconds: MonotonicClock.nowNanoseconds()
      )
    )
  }

  private static let demoDeviceID = DeviceID(
    rawValue: "vec-demo"
  )

  /// Reserves only active-Profile fallback chords on the main event target.
  private func registerKeyboardFallbacks() async {
    let registrations = ProfileBindingResolver(
      profile: profile
    ).keyboardFallbacks
    let runtime = self.runtime
    let failures = await MainActor.run {
      let source =
        keyboardFallbackInputSource
        ?? KeyboardFallbackInputSource { registration, phase, timestamp in
          runtime.handleKeyboardFallback(
            registration,
            phase: phase,
            timestampNanoseconds: timestamp
          )
        }
      keyboardFallbackInputSource = source
      return source.replace(with: registrations)
    }
    eventRelay.publishKeyboardFallbackFailures(failures)
  }

  /// Releases global shortcuts before sleep or process shutdown.
  private func stopKeyboardFallbacks() async {
    await MainActor.run {
      keyboardFallbackInputSource?.stop()
      keyboardFallbackInputSource = nil
    }
    eventRelay.publishKeyboardFallbackFailures([])
  }
}

/// Serializes application lifecycle and publishes one immutable snapshot.
actor ApplicationRuntime {
  typealias SnapshotHandler =
    @Sendable (ApplicationSnapshot) -> Void

  nonisolated let initialSnapshot: ApplicationSnapshot
  nonisolated let isDemoMode: Bool
  nonisolated let showsDemoPressedState: Bool
  nonisolated let installationLocation: ApplicationInstallationLocation
  nonisolated let deviceDescriptor: DeviceModelDescriptor

  private let profileStore: any ProfilePersisting
  private let system: any ApplicationSystemControlling
  private let process: any ApplicationProcessControlling
  private var snapshot: ApplicationSnapshot
  private var snapshotHandler: SnapshotHandler?
  private var pollingTask: Task<Void, Never>?
  private var warmUpTask: Task<Void, Never>?
  private let loadsProfileOnStart: Bool
  private var hasLoadedProfile = false
  private var isStarted = false
  private var isStopped = false
  private var isSuspended = false
  private var localAISettings: LocalAISettings
  private var localAIProviderTestGeneration: UInt64 = 0

  /// Creates the complete live or deterministic demo application runtime.
  @MainActor
  static func make(
    arguments: [String],
    profileStore providedProfileStore:
      (any ProfilePersisting)? = nil,
    preferredMicrophoneUID: String? = nil,
    localAISettings: LocalAISettings = .default
  ) -> ApplicationRuntime {
    let isDemoMode = arguments.contains("--demo")
    let showsDemoPressedState =
      isDemoMode && arguments.contains("--ui-pressed")
    let store =
      providedProfileStore
      ?? (isDemoMode
        ? PreviewProfileStore()
        : makeProfileStore())
    let installationLocation = ApplicationInstallationLocation(
      bundleURL: Bundle.main.bundleURL
    )

    let demoState =
      isDemoMode
      ? ApplicationSystemState(
        accessibilityTrusted:
          !arguments.contains("--ui-permission-needed"),
        microphonePermission:
          arguments.contains("--ui-microphone-needed")
          ? .notDetermined : .authorized,
        speechRecognitionPermission:
          arguments.contains("--ui-speech-needed")
          ? .notDetermined : .authorized,
        launchAtLogin:
          SMAppService.mainApp.status == .enabled
      )
      : nil
    let system = SystemApplicationController(
      stateOverride: demoState
    )
    let systemState = system.currentState()
    let transcription = demoTranscriptionSnapshot(
      arguments: arguments,
      isDemoMode: isDemoMode
    )
    let initialSnapshot = ApplicationSnapshot(
      envelope:
        isDemoMode ? demoEnvelope() : .defaultEnvelope(),
      accessibilityTrusted:
        systemState.accessibilityTrusted,
      microphonePermission:
        systemState.microphonePermission,
      speechRecognitionPermission:
        systemState.speechRecognitionPermission,
      transcription: transcription,
      localAIProvider: localAISettings.provider,
      launchAtLogin: systemState.launchAtLogin,
      recoveryNotice: nil
    )

    return ApplicationRuntime(
      initialSnapshot: initialSnapshot,
      isDemoMode: isDemoMode,
      showsDemoPressedState: showsDemoPressedState,
      installationLocation: installationLocation,
      profileStore: store,
      system: system,
      preferredMicrophoneUID: preferredMicrophoneUID,
      localAISettings: localAISettings,
      loadsProfileOnStart: !isDemoMode
    )
  }

  /// Produces deterministic active and failure states for packaged UI review.
  private static func demoTranscriptionSnapshot(
    arguments: [String],
    isDemoMode: Bool
  ) -> TranscriptionSnapshot {
    guard isDemoMode else {
      return .idle
    }
    if arguments.contains("--ui-transcription-failure") {
      return TranscriptionSnapshot(
        sessionID: UUID(),
        phase: .failed,
        volatileText: "",
        finalText: "",
        targetApplicationName: "Focused app",
        failure: .noFocusedTextField
      )
    }
    if arguments.contains("--ui-transcribing") {
      return TranscriptionSnapshot(
        sessionID: UUID(),
        phase: .listening,
        volatileText:
          "Hardware Controller is transcribing locally…",
        finalText: "",
        targetApplicationName: "Notes",
        failure: nil
      )
    }
    return .idle
  }

  /// Creates distinct no-write Coding and Music work modes for UI demos.
  private static func demoEnvelope() -> ProfileEnvelope {
    var coding = Profile.defaultProfile
    coding.name = "Coding"
    let music = Profile(
      name: "Music",
      deviceConfigurations: [
        ProfileDeviceConfiguration(
          matchRule: DeviceMatchRule(modelID: .vecInfinity3),
          bindings: [
            Binding(
              controlID: .left,
              interactionMode: .momentary,
              action: .keyboardShortcut(
                KeyboardShortcut(
                  keyCode: 123,
                  modifiers: [.command]
                )
              )
            ),
            Binding(
              controlID: .center,
              interactionMode: .momentary,
              action: .keyboardShortcut(
                KeyboardShortcut(keyCode: 49, modifiers: [])
              )
            ),
            Binding(
              controlID: .right,
              interactionMode: .momentary,
              action: .keyboardShortcut(
                KeyboardShortcut(
                  keyCode: 124,
                  modifiers: [.command]
                )
              )
            ),
          ]
        )
      ]
    )
    return ProfileEnvelope(
      activeProfileID: coding.id,
      profiles: [coding, music]
    )
  }

  /// Creates a runtime around injected adapters for focused tests.
  init(
    initialSnapshot: ApplicationSnapshot,
    isDemoMode: Bool,
    showsDemoPressedState: Bool,
    installationLocation: ApplicationInstallationLocation,
    profileStore: any ProfilePersisting,
    system: any ApplicationSystemControlling,
    preferredMicrophoneUID: String? = nil,
    localAISettings: LocalAISettings = .default,
    loadsProfileOnStart: Bool = false,
    processFactory:
      @Sendable (
        Profile,
        Bool,
        Bool,
        String?,
        LocalAISettings,
        ApplicationProcessEventRelay
      ) -> any ApplicationProcessControlling = {
        profile,
        isDemoMode,
        showsDemoPressedState,
        preferredMicrophoneUID,
        localAISettings,
        eventRelay in
        LiveApplicationProcess(
          profile: profile,
          isDemoMode: isDemoMode,
          showsDemoPressedState: showsDemoPressedState,
          preferredMicrophoneUID: preferredMicrophoneUID,
          localAISettings: localAISettings,
          eventRelay: eventRelay
        )
      }
  ) {
    let eventRelay = ApplicationProcessEventRelay()
    let activeProfile =
      initialSnapshot.envelope.activeProfile ?? .defaultProfile
    let process = processFactory(
      activeProfile,
      isDemoMode,
      showsDemoPressedState,
      preferredMicrophoneUID,
      localAISettings,
      eventRelay
    )

    self.initialSnapshot = initialSnapshot
    self.isDemoMode = isDemoMode
    self.showsDemoPressedState = showsDemoPressedState
    self.installationLocation = installationLocation
    deviceDescriptor = process.deviceDescriptor
    self.profileStore = profileStore
    self.system = system
    self.loadsProfileOnStart = loadsProfileOnStart
    self.localAISettings = localAISettings
    self.process = process
    snapshot = initialSnapshot

    eventRelay.installHandler { [weak self] event in
      Task {
        await self?.receive(event)
      }
    }
  }

  /// Starts process work and continuous system-state observation once.
  func start(
    snapshotHandler: @escaping SnapshotHandler
  ) async {
    self.snapshotHandler = snapshotHandler
    guard !isStopped else {
      publish()
      return
    }
    guard !isStarted else {
      publish()
      return
    }
    isStarted = true

    assign(systemState: await system.currentState())
    await loadProfileIfNeeded()
    guard !Task.isCancelled else {
      isStarted = false
      return
    }
    updateRuntimeAvailability()
    switch await process.start() {
    case .started:
      snapshot.hardwareInputFailure = nil
    case .failed(let failure):
      snapshot.hardwareInputFailure = failure
    }
    publish()

    let readiness = await process.localAIReadiness()
    guard isStarted, !isStopped else {
      return
    }
    guard readiness != snapshot.localAIReadiness else {
      startPolling()
      return
    }
    snapshot.localAIReadiness = readiness
    updateRuntimeAvailability()
    publish()

    startPolling()
  }

  private func startPolling() {
    pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .milliseconds(500))
        } catch {
          return
        }
        await self?.refreshSystemState()
      }
    }
  }

  /// Stops every owned task and process seam exactly once.
  func stop() async {
    guard isStarted else {
      return
    }
    isStarted = false
    isStopped = true
    pollingTask?.cancel()
    pollingTask = nil
    warmUpTask?.cancel()
    warmUpTask = nil
    localAIProviderTestGeneration &+= 1
    isSuspended = false
    await process.stop()
  }

  /// Loads persisted Profile state off the main actor before input starts.
  private func loadProfileIfNeeded() async {
    guard loadsProfileOnStart, !hasLoadedProfile else {
      return
    }
    hasLoadedProfile = true
    let result = profileStore.load()
    snapshot.envelope = result.envelope
    snapshot.recoveryNotice = Self.recoveryNotice(
      for: result.issue
    )
    await process.setProfile(activeProfile)
  }

  /// Ends active Actions and input before system sleep.
  func prepareForSleep() async {
    guard isStarted, !isSuspended else {
      return
    }
    isSuspended = true
    warmUpTask?.cancel()
    warmUpTask = nil
    snapshot.transcriptionPrepared = false
    snapshot.transcriptionPreparationFailure = nil
    await process.suspend()
    snapshot.hardwareInputFailure = nil
    publish()
  }

  /// Restarts hardware input after system wake.
  func resumeAfterWake() async {
    guard isStarted, isSuspended else {
      return
    }
    isSuspended = false
    switch await process.resume() {
    case .started:
      snapshot.hardwareInputFailure = nil
    case .failed(let failure):
      snapshot.hardwareInputFailure = failure
    }
    updateRuntimeAvailability()
    publish()
  }

  /// Restarts hardware input and publishes any actionable failure.
  func retryHardwareInput() {
    switch process.retryHardwareInput() {
    case .started:
      snapshot.hardwareInputFailure = nil
    case .failed(let failure):
      snapshot.hardwareInputFailure = failure
    }
    publish()
  }

  /// Changes one Binding Action transactionally.
  func setAction(
    _ kind: ActionKind,
    for controlID: ControlID
  ) async {
    guard
      let configuration = activeProfile.configuration(
        matching: DeviceMatchRule(modelID: deviceDescriptor.modelID)
      )
    else {
      publishMissingDeviceConfiguration()
      return
    }
    await setAction(
      kind,
      for: controlID,
      profileID: activeProfile.id,
      configurationID: configuration.id
    )
  }

  /// Changes one Binding Action in an identified Profile setup.
  func setAction(
    _ kind: ActionKind,
    for controlID: ControlID,
    profileID: UUID,
    configurationID: UUID
  ) async {
    guard
      var binding = binding(
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    else {
      publishMissingBinding()
      return
    }
    switch kind {
    case .noAction:
      binding.action = .noAction
      binding.activationShortcut = nil
    case .dictation:
      binding.action = .dictation()
    case .localAIDictation:
      binding.action = .localAIDictation()
    case .keyboardShortcut:
      binding.action = .keyboardShortcut(
        binding.action.shortcut
          ?? KeyboardShortcut(
            keyCode: 15,
            modifiers: [.command]
          )
      )
    }
    await save(
      binding,
      profileID: profileID,
      configurationID: configurationID
    )
  }

  /// Changes one Binding interaction mode transactionally.
  func setInteractionMode(
    _ mode: InteractionMode,
    for controlID: ControlID
  ) async {
    guard
      let configuration = activeProfile.configuration(
        matching: DeviceMatchRule(modelID: deviceDescriptor.modelID)
      )
    else {
      publishMissingDeviceConfiguration()
      return
    }
    await setInteractionMode(
      mode,
      for: controlID,
      profileID: activeProfile.id,
      configurationID: configuration.id
    )
  }

  /// Changes one interaction mode in an identified Profile setup.
  func setInteractionMode(
    _ mode: InteractionMode,
    for controlID: ControlID,
    profileID: UUID,
    configurationID: UUID
  ) async {
    guard
      var binding = binding(
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    else {
      publishMissingBinding()
      return
    }
    binding.interactionMode = mode
    await save(
      binding,
      profileID: profileID,
      configurationID: configurationID
    )
  }

  /// Changes one Binding shortcut transactionally.
  func setShortcut(
    _ shortcut: KeyboardShortcut,
    for controlID: ControlID
  ) async {
    guard
      let configuration = activeProfile.configuration(
        matching: DeviceMatchRule(modelID: deviceDescriptor.modelID)
      )
    else {
      publishMissingDeviceConfiguration()
      return
    }
    await setShortcut(
      shortcut,
      for: controlID,
      profileID: activeProfile.id,
      configurationID: configuration.id
    )
  }

  /// Changes one shortcut in an identified Profile setup.
  func setShortcut(
    _ shortcut: KeyboardShortcut,
    for controlID: ControlID,
    profileID: UUID,
    configurationID: UUID
  ) async {
    guard
      var binding = binding(
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    else {
      publishMissingBinding()
      return
    }
    binding.action.shortcut = shortcut
    await save(
      binding,
      profileID: profileID,
      configurationID: configurationID
    )
  }

  /// Changes one active Binding keyboard fallback transactionally.
  func setActivationShortcut(
    _ shortcut: KeyboardShortcut?,
    for controlID: ControlID
  ) async {
    guard
      let configuration = activeProfile.configuration(
        matching: DeviceMatchRule(modelID: deviceDescriptor.modelID)
      )
    else {
      publishMissingDeviceConfiguration()
      return
    }
    await setActivationShortcut(
      shortcut,
      for: controlID,
      profileID: activeProfile.id,
      configurationID: configuration.id
    )
  }

  /// Changes one identified Binding keyboard fallback transactionally.
  func setActivationShortcut(
    _ shortcut: KeyboardShortcut?,
    for controlID: ControlID,
    profileID: UUID,
    configurationID: UUID
  ) async {
    guard
      var binding = binding(
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    else {
      publishMissingBinding()
      return
    }
    guard binding.action.kind != .noAction || shortcut == nil else {
      publishProfileError(
        "Choose an Action before adding a keyboard fallback."
      )
      return
    }
    binding.activationShortcut = shortcut
    await save(
      binding,
      profileID: profileID,
      configurationID: configurationID
    )
  }

  /// Creates one safely inactive work mode for connected Device models.
  func createProfile() async {
    var candidate = snapshot.envelope
    let profile = Profile.safeProfile(
      name: candidate.uniqueName(base: "New Profile"),
      deviceDescriptors: connectedDeviceDescriptors
    )
    candidate.profiles.append(profile)
    await persist(candidate, runtimeProfile: nil)
  }

  /// Copies one complete work mode without activating the copy.
  func duplicateProfile(id: UUID) async {
    guard let source = snapshot.envelope.profile(id: id) else {
      publishProfileError("The selected profile no longer exists.")
      return
    }
    var candidate = snapshot.envelope
    let duplicate = source.duplicated(
      name: candidate.uniqueName(base: "\(source.name) Copy")
    )
    candidate.profiles.append(duplicate)
    await persist(candidate, runtimeProfile: nil)
  }

  /// Renames one work mode after normalizing user-entered whitespace.
  func renameProfile(id: UUID, name: String) async {
    guard var profile = snapshot.envelope.profile(id: id) else {
      publishProfileError("The selected profile no longer exists.")
      return
    }
    profile.name = name.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    var candidate = snapshot.envelope
    candidate.setProfile(profile)
    await persist(candidate, runtimeProfile: nil)
  }

  /// Deletes one work mode and safely replaces it when it is active.
  func deleteProfile(
    id: UUID,
    replacementProfileID: UUID?
  ) async {
    var candidate = snapshot.envelope
    do {
      try candidate.removeProfile(
        id: id,
        replacementProfileID: replacementProfileID
      )
    } catch {
      publishProfileError("The selected profile could not be deleted.")
      return
    }
    let runtimeProfile =
      snapshot.envelope.activeProfileID == id
      ? candidate.activeProfile : nil
    await persist(candidate, runtimeProfile: runtimeProfile)
  }

  /// Makes one persisted Profile authoritative for every connected Device.
  func activateProfile(id: UUID) async {
    guard let profile = snapshot.envelope.profile(id: id) else {
      publishProfileError("The selected profile no longer exists.")
      return
    }
    guard id != snapshot.envelope.activeProfileID else {
      return
    }
    var candidate = snapshot.envelope
    candidate.activeProfileID = id
    await persist(candidate, runtimeProfile: profile)
  }

  /// Adds one inert Device setup to an identified Profile.
  func addDeviceConfiguration(
    profileID: UUID,
    descriptor: DeviceModelDescriptor
  ) async {
    guard var profile = snapshot.envelope.profile(id: profileID) else {
      publishProfileError("The selected profile no longer exists.")
      return
    }
    let matchRule = DeviceMatchRule(modelID: descriptor.modelID)
    guard profile.configuration(matching: matchRule) == nil else {
      return
    }
    profile.setDeviceConfiguration(
      Profile.safeDeviceConfiguration(for: descriptor)
    )
    await persistProfile(profile)
  }

  /// Removes one Device setup and leaves unmatched hardware inert.
  func removeDeviceConfiguration(
    profileID: UUID,
    configurationID: UUID
  ) async {
    guard var profile = snapshot.envelope.profile(id: profileID) else {
      publishProfileError("The selected profile no longer exists.")
      return
    }
    guard
      profile.deviceConfigurations.contains(
        where: { $0.id == configurationID }
      )
    else {
      publishMissingDeviceConfiguration()
      return
    }
    profile.removeDeviceConfiguration(id: configurationID)
    await persistProfile(profile)
  }

  /// Runs one Binding through the process implementation.
  func testBinding(_ controlID: ControlID) {
    process.testBinding(controlID)
  }

  /// Sends one demo transition through the process implementation.
  func simulate(
    _ controlID: ControlID,
    phase: ControlPhase
  ) {
    process.simulate(controlID, phase: phase)
  }

  /// Requests Accessibility and reapplies Action availability.
  func requestAccessibility() async {
    await request(.accessibility)
  }

  /// Requests Microphone access and reapplies Action availability.
  func requestMicrophone() async {
    await request(.microphone)
  }

  /// Reconfigures capture and rebuilds authorized warm resources.
  func setPreferredMicrophoneUID(_ uniqueID: String?) async {
    warmUpTask?.cancel()
    warmUpTask = nil
    snapshot.transcriptionPrepared = false
    snapshot.transcriptionPreparationFailure = nil
    await process.setPreferredMicrophoneUID(uniqueID)
    updateRuntimeAvailability()
    publish()
  }

  /// Applies persisted Local AI settings and refreshes provider readiness.
  func setLocalAISettings(_ settings: LocalAISettings) async {
    localAIProviderTestGeneration &+= 1
    localAISettings = settings
    snapshot.localAIProvider = settings.provider
    snapshot.localAIProviderTest = .idle
    snapshot.localAIReadiness = .checking
    updateRuntimeAvailability()
    publish()
    snapshot.localAIReadiness = await process.setLocalAISettings(
      settings,
      profileName: activeProfile.name
    )
    updateRuntimeAvailability()
    publish()
  }

  /// Rechecks Ollama installation, model digests, and Apple availability.
  func refreshLocalAIReadiness() async {
    snapshot.localAIReadiness = .checking
    updateRuntimeAvailability()
    publish()
    snapshot.localAIReadiness = await process.localAIReadiness()
    updateRuntimeAvailability()
    publish()
  }

  /// Runs a sanitized local provider test and publishes the typed result.
  func testLocalAIProvider() async {
    guard snapshot.localAIProviderTest != .running else {
      return
    }
    localAIProviderTestGeneration &+= 1
    let generation = localAIProviderTestGeneration
    snapshot.localAIProviderTest = .running
    publish()
    let failure = await process.testLocalAIProvider()
    guard
      generation == localAIProviderTestGeneration,
      isStarted,
      !isStopped
    else {
      return
    }
    if let failure {
      snapshot.localAIProviderTest = .failed(failure)
    } else {
      snapshot.localAIProviderTest = .passed
    }
    publish()
  }

  /// Requests Speech Recognition and reapplies Action availability.
  func requestSpeechRecognition() async {
    await request(.speechRecognition)
  }

  /// Requests one permission and reapplies Action availability.
  private func request(
    _ permission: ApplicationPermission
  ) async {
    let state = await system.request(permission)
    apply(systemState: state)
  }

  /// Changes login-item registration when installation permits it.
  func setLaunchAtLogin(_ enabled: Bool) async {
    guard installationLocation.canRegisterLoginItem else {
      snapshot.lastError =
        "Move Hardware Controller to Applications before enabling Launch at Login."
      publish()
      return
    }

    do {
      let state = try await system.setLaunchAtLogin(enabled)
      snapshot.launchAtLogin = state.launchAtLogin
      snapshot.lastError = nil
    } catch {
      let state = await system.currentState()
      snapshot.launchAtLogin = state.launchAtLogin
      snapshot.lastError =
        "Launch at Login could not be changed: \(error.localizedDescription)"
    }
    publish()
  }

  /// Clears presentation notices without changing runtime state.
  func clearNotice() {
    snapshot.recoveryNotice = nil
    snapshot.lastError = nil
    publish()
  }

  /// Receives process snapshots without joining the input hot path.
  private func receive(
    _ event: ApplicationProcessEventRelay.Event
  ) {
    switch event {
    case .runtime(let runtimeSnapshot):
      snapshot.runtime = runtimeSnapshot
    case .transcription(let transcriptionSnapshot):
      snapshot.transcription = transcriptionSnapshot
    case .localAIDictation(let localAISnapshot):
      snapshot.localAIDictation = localAISnapshot
    case .keyboardFallbackFailures(let failures):
      snapshot.keyboardFallbackFailures = failures
    }
    publish()
  }

  /// Polls system state and reacts only to actual changes.
  private func refreshSystemState() async {
    let state = await system.currentState()
    let changed =
      state.accessibilityTrusted
      != snapshot.accessibilityTrusted
      || state.microphonePermission
        != snapshot.microphonePermission
      || state.speechRecognitionPermission
        != snapshot.speechRecognitionPermission
      || state.launchAtLogin != snapshot.launchAtLogin
    guard changed else {
      return
    }
    apply(systemState: state)
  }

  /// Applies system state and restarts preparation when required.
  private func apply(systemState: ApplicationSystemState) {
    assign(systemState: systemState)
    updateRuntimeAvailability()
    publish()
  }

  /// Assigns authoritative system state without producing partial effects.
  private func assign(systemState: ApplicationSystemState) {
    snapshot.accessibilityTrusted =
      systemState.accessibilityTrusted
    snapshot.microphonePermission =
      systemState.microphonePermission
    snapshot.speechRecognitionPermission =
      systemState.speechRecognitionPermission
    snapshot.launchAtLogin = systemState.launchAtLogin
  }

  /// Applies Action availability and starts one cancellable warm-up.
  private func updateRuntimeAvailability() {
    let availability = ActionExecutionAvailability(
      dictationAllowed: canExecuteDictation,
      localAIDictationAllowed: canExecuteLocalAIDictation,
      keyboardShortcutsAllowed:
        canExecuteKeyboardShortcuts
    )
    process.setAvailability(availability)
    warmUpTask?.cancel()
    warmUpTask = nil
    snapshot.transcriptionPrepared = false
    snapshot.transcriptionPreparationFailure = nil

    guard canExecuteDictation, !isSuspended else {
      return
    }
    if isDemoMode {
      snapshot.transcriptionPrepared = true
      return
    }

    warmUpTask = Task { [weak self, process] in
      let failure = await process.warmUpTranscription()
      guard !Task.isCancelled else {
        return
      }
      await self?.finishWarmUp(failure)
    }
  }

  /// Publishes the result of the latest non-canceled warm-up.
  private func finishWarmUp(
    _ failure: TranscriptionFailure?
  ) {
    snapshot.transcriptionPrepared = failure == nil
    snapshot.transcriptionPreparationFailure = failure
    publish()
  }

  /// Returns the active Profile with a safe in-memory fallback.
  private var activeProfile: Profile {
    snapshot.envelope.activeProfile ?? .defaultProfile
  }

  /// Returns unique connected Device descriptors for new work modes.
  private var connectedDeviceDescriptors: [DeviceModelDescriptor] {
    var modelIDs: Set<DeviceModelID> = []
    return snapshot.runtime.devices.compactMap { device in
      guard modelIDs.insert(device.model.modelID).inserted else {
        return nil
      }
      return device.model
    }
  }

  /// Returns one Binding by persistent Profile and setup identity.
  private func binding(
    for controlID: ControlID,
    profileID: UUID,
    configurationID: UUID
  ) -> Binding? {
    snapshot.envelope.profile(id: profileID)?
      .deviceConfigurations.first {
        $0.id == configurationID
      }?
      .binding(for: controlID)
  }

  /// Saves and publishes one candidate Binding atomically.
  private func save(
    _ binding: Binding,
    profileID: UUID,
    configurationID: UUID
  ) async {
    guard var profile = snapshot.envelope.profile(id: profileID) else {
      publishProfileError("The selected profile no longer exists.")
      return
    }
    do {
      try profile.setBinding(
        binding,
        configurationID: configurationID
      )
    } catch {
      publishMissingDeviceConfiguration()
      return
    }
    await persistProfile(profile)
  }

  /// Persists one edited Profile and updates runtime only when active.
  private func persistProfile(_ profile: Profile) async {
    var candidate = snapshot.envelope
    candidate.setProfile(profile)
    await persist(
      candidate,
      runtimeProfile:
        profile.id == candidate.activeProfileID ? profile : nil
    )
  }

  /// Commits one complete envelope before publishing or applying runtime state.
  private func persist(
    _ candidate: ProfileEnvelope,
    runtimeProfile: Profile?
  ) async {
    do {
      try profileStore.save(candidate)
      if let runtimeProfile {
        await process.setProfile(runtimeProfile)
      }
      snapshot.envelope = candidate
      snapshot.lastError = nil
      if runtimeProfile != nil {
        updateRuntimeAvailability()
      }
    } catch {
      snapshot.lastError =
        "Your profiles could not be saved: \(error.localizedDescription)"
    }
    publish()
  }

  /// Publishes one stale Profile selection failure.
  private func publishProfileError(_ message: String) {
    snapshot.lastError = message
    publish()
  }

  /// Publishes one stale Device-configuration failure.
  private func publishMissingDeviceConfiguration() {
    publishProfileError(
      "The selected profile has no setup for this Device."
    )
  }

  /// Publishes one stale Binding failure.
  private func publishMissingBinding() {
    publishProfileError(
      "The selected Device setup has no Binding for this Control."
    )
  }

  /// Publishes the current snapshot to the presentation observer.
  private func publish() {
    snapshotHandler?(snapshot)
  }

  /// Reports whether Dictation can currently execute.
  private var canExecuteDictation: Bool {
    !installationLocation.requiresInstallation
      && snapshot.accessibilityTrusted
      && snapshot.microphonePermission == .authorized
      && snapshot.speechRecognitionPermission == .authorized
  }

  /// Reports whether permissions and the selected local provider are ready.
  private var canExecuteLocalAIDictation: Bool {
    canExecuteDictation
      && snapshot.localAIReadiness.readiness(
        for: localAISettings.provider
      ).state.canRun
  }

  /// Reports whether synthetic shortcuts can currently execute.
  private var canExecuteKeyboardShortcuts: Bool {
    !installationLocation.requiresInstallation
      && snapshot.accessibilityTrusted
  }

  /// Converts a Profile-load issue into concise recovery copy.
  private static func recoveryNotice(
    for issue: ProfileStoreIssue?
  ) -> String? {
    switch issue {
    case .couldNotReadFile(let message):
      "Your Profiles could not be read: \(message)"
    case .requiresNewerApp:
      "Your Profiles were created by a newer version of Hardware Controller. Update the app to use them; the saved file was not changed."
    case .recoveredInvalidFile(
      let backupURL,
      let backupFailureMessage
    ):
      if let backupURL {
        "Damaged Profiles were preserved at \(backupURL.lastPathComponent)."
      } else {
        "Damaged Profiles could not be preserved: \(backupFailureMessage ?? "Unknown backup error.")"
      }
    case .migratedOwnedDictation:
      "Dictation now runs locally in Hardware Controller; its old macOS shortcut was removed."
    case .migratedDeviceConfigurations:
      "Your Profiles were upgraded to support independent Device setups."
    case .migratedKeyboardFallbacks:
      "Your Profiles were upgraded to support optional keyboard fallbacks."
    case .migratedLocalAIDictation:
      "Your Profiles were upgraded to support Local AI Dictation. Existing Actions were unchanged."
    case .migrationNotPersisted(let message):
      "Your Profiles were migrated for this session but could not be saved: \(message)"
    case nil:
      nil
    }
  }

  /// Creates the standard Application Support Profile store.
  @MainActor
  private static func makeProfileStore() -> any ProfilePersisting {
    do {
      return try ProfileStore.applicationSupportStore()
    } catch {
      return UnavailableProfileStore(error: error)
    }
  }
}

/// Fails explicitly when Profile storage or identity migration is unavailable.
private struct UnavailableProfileStore: ProfilePersisting {
  let error: any Error & Sendable

  /// Reports the construction failure without touching local data.
  func load() -> ProfileLoadResult {
    ProfileLoadResult(
      envelope: .defaultEnvelope(),
      issue: .couldNotReadFile(message: error.localizedDescription)
    )
  }

  /// Preserves the original construction failure.
  func save(_ envelope: ProfileEnvelope) throws {
    throw error
  }
}

/// Accepts demo Dictation commands without starting system work.
private struct PreviewDictationCommandDispatcher:
  DictationCommandDispatching
{
  /// Accepts every deterministic preview command.
  func submit(_ command: DictationCommand) -> Bool {
    true
  }

  /// Has no process resources to release.
  func shutdown() {}
}
