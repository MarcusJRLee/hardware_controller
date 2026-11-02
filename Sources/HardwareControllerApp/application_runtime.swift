import Foundation
import HardwareControllerCore
import HardwareControllerMac
import ServiceManagement

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
  private var voiceTriggerSettings: VoiceTriggerSettings
  private var localAIProviderTestGeneration: UInt64 = 0

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
    speechEngine: SpeechEngineConfiguration,
    voiceTriggerSettings: VoiceTriggerSettings = .default,
    voiceSessionHistory: (any VoiceSessionHistoryRecording)? = nil,
    loadsProfileOnStart: Bool = false,
    processFactory:
      @Sendable (
        Profile,
        Bool,
        Bool,
        String?,
        LocalAISettings,
        SpeechEngineConfiguration,
        (any VoiceSessionHistoryRecording)?,
        ApplicationProcessEventRelay
      ) -> any ApplicationProcessControlling = {
        profile,
        isDemoMode,
        showsDemoPressedState,
        preferredMicrophoneUID,
        localAISettings,
        speechEngine,
        voiceSessionHistory,
        eventRelay in
        LiveApplicationProcess(
          profile: profile,
          isDemoMode: isDemoMode,
          showsDemoPressedState: showsDemoPressedState,
          preferredMicrophoneUID: preferredMicrophoneUID,
          localAISettings: localAISettings,
          speechEngine: speechEngine,
          voiceSessionHistory: voiceSessionHistory,
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
      speechEngine,
      voiceSessionHistory,
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
    self.voiceTriggerSettings = voiceTriggerSettings
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
    do {
      snapshot.voiceShortcutFailure =
        try await process
        .setVoiceTriggerSettings(voiceTriggerSettings)
    } catch {
      snapshot.lastError =
        "Voice capture shortcut settings could not be applied."
    }
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

  /// Validates, commits, and publishes one Profile edit transactionally.
  func edit(_ edit: ProfileEdit) async {
    let context = ProfileEditContext(
      primaryModelID: deviceDescriptor.modelID,
      connectedDevices: connectedDeviceDescriptors
    )
    let result: ProfileEditResult?
    do {
      result = try snapshot.envelope.applying(edit, in: context)
    } catch {
      snapshot.lastError = Self.message(for: error)
      publish()
      return
    }
    guard let result else {
      return
    }
    await persist(result.envelope, runtimeProfile: result.runtimeProfile)
  }

  /// Runs one Binding through the process implementation.
  func testBinding(_ controlID: ControlID) {
    process.testBinding(controlID)
  }

  /// Routes one in-app command through the process-owned Voice session.
  @discardableResult
  func submitVoiceCapture(_ command: DictationCommand) -> Bool {
    guard isStarted, !isStopped, !isSuspended else {
      return false
    }
    if command == .begin, !canExecuteLocalAIDictation {
      return false
    }
    let accepted = process.submitVoiceCapture(command)
    if !accepted {
      snapshot.lastError =
        "Voice capture is busy. Wait for the current session to finish."
      publish()
    }
    return accepted
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
  func setSpeechEngineConfiguration(_ configuration: SpeechEngineConfiguration) async {
    if configuration.selection == .apple {
      snapshot.speechEngineFallback = nil
      publish()
    }
    await process.setSpeechEngineConfiguration(configuration)
  }

  func setLocalAISettings(_ settings: LocalAISettings) async {
    localAIProviderTestGeneration &+= 1
    localAISettings = settings
    snapshot.localAIProvider = settings.provider
    snapshot.localAIStyle = settings.style
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

  /// Applies a persisted Voice chord and publishes any reservation conflict.
  func setVoiceTriggerSettings(_ settings: VoiceTriggerSettings) async {
    do {
      let failure = try await process.setVoiceTriggerSettings(settings)
      voiceTriggerSettings = settings
      snapshot.voiceShortcutFailure = failure
      snapshot.lastError = nil
    } catch {
      snapshot.lastError =
        "Voice capture shortcut settings could not be applied."
    }
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
    case .voiceShortcutFailure(let failure):
      snapshot.voiceShortcutFailure = failure
    case .speechEngineFallback(let reason):
      snapshot.speechEngineFallback = reason
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
      && (localAISettings.style.kind == .verbatim
        || snapshot.localAIReadiness.readiness(
          for: localAISettings.provider
        ).state.canRun)
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

  /// Explains one rejected Profile edit in user-facing terms.
  private static func message(for failure: ProfileEditFailure) -> String {
    switch failure {
    case .profileMissing:
      "The selected profile no longer exists."
    case .deviceConfigurationMissing:
      "The selected profile has no setup for this Device."
    case .bindingMissing:
      "The selected Device setup has no Binding for this Control."
    case .activationShortcutNeedsAction:
      "Choose an Action before adding a keyboard fallback."
    case .deletionRejected:
      "The selected profile could not be deleted."
    }
  }
}
