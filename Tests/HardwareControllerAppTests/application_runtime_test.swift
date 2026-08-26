import Foundation
import HardwareControllerCore
import HardwareControllerMac
import Testing

@testable import HardwareControllerApp

@MainActor
struct ApplicationRuntimeTest {
  /// Starts, publishes, and stops every process seam exactly once.
  @Test
  func lifecycleIsOwnedByOneRuntime() async throws {
    let fixture = RuntimeFixture()

    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    await fixture.runtime.stop()

    #expect(fixture.process.startCount == 1)
    #expect(fixture.process.stopCount == 1)
    #expect(fixture.process.availabilities.count == 1)
    #expect(!fixture.snapshots.values.isEmpty)
  }

  /// Starts hardware before a slow optional provider readiness check returns.
  @Test(.timeLimit(.minutes(1)))
  func localAIReadinessNeverDelaysHardwareStartup() async {
    let fixture = RuntimeFixture(
      blocksLocalAIReadiness: true
    )

    let start = Task {
      await fixture.runtime.start(
        snapshotHandler: fixture.snapshots.append
      )
    }
    await fixture.process.waitUntilLocalAIReadinessIsBlocked()

    #expect(fixture.process.startCount == 1)
    fixture.process.completeLocalAIReadiness()
    await start.value
    await fixture.runtime.stop()
  }

  /// Keeps persisted and process Profile state unchanged after a failed save.
  @Test
  func failedProfileSaveIsTransactional() async throws {
    let fixture = RuntimeFixture(profileSaveFails: true)
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )

    await fixture.runtime.setAction(
      .keyboardShortcut,
      for: .left
    )
    try await waitUntil {
      fixture.snapshots.values.last?.lastError != nil
    }

    let snapshot = try #require(fixture.snapshots.values.last)
    #expect(
      snapshot.envelope.activeProfile?
        .binding(
          for: .left,
          matching: DeviceMatchRule(modelID: .vecInfinity3)
        )?.action == .noAction
    )
    #expect(fixture.process.profiles.isEmpty)
    await fixture.runtime.stop()
  }

  /// Reapplies Action availability and warm-up after permission recovery.
  @Test
  func permissionRecoveryWarmsTranscription() async throws {
    let initialSystem = ApplicationSystemState(
      accessibilityTrusted: true,
      microphonePermission: .denied,
      speechRecognitionPermission: .authorized,
      launchAtLogin: false
    )
    let recoveredSystem = ApplicationSystemState(
      accessibilityTrusted: true,
      microphonePermission: .authorized,
      speechRecognitionPermission: .authorized,
      launchAtLogin: false
    )
    let fixture = RuntimeFixture(systemState: initialSystem)
    fixture.system.requestedState = recoveredSystem
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )

    await fixture.runtime.requestMicrophone()
    try await waitUntil {
      fixture.snapshots.values.last?
        .transcriptionPrepared == true
    }

    #expect(
      fixture.process.availabilities.last
        == ActionExecutionAvailability(
          dictationAllowed: true,
          keyboardShortcutsAllowed: true
        )
    )
    #expect(fixture.process.warmUpCount == 1)
    await fixture.runtime.stop()
  }

  /// Enables only Local AI Dictation when its selected provider is ready.
  @Test
  func localAIReadinessGatesItsActionIndependently() async {
    let readiness = LocalAIReadinessSnapshot(
      apple: LocalAIProviderReadiness(
        provider: .appleOnDevice,
        state: .ready
      ),
      ollama: LocalAIProviderReadiness(
        provider: .ollama,
        state: .modelMissing("qwen3.5:4b")
      )
    )
    let fixture = RuntimeFixture(localAIReadiness: readiness)

    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )

    #expect(
      fixture.process.availabilities.last
        == ActionExecutionAvailability(
          dictationAllowed: true,
          localAIDictationAllowed: true,
          keyboardShortcutsAllowed: true
        )
    )
    await fixture.runtime.stop()
  }

  /// Publishes sanitized provider-test progress and success.
  @Test
  func localAIProviderTestPublishesItsResult() async {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )

    await fixture.runtime.testLocalAIProvider()

    #expect(
      fixture.snapshots.values.contains {
        $0.localAIProviderTest == .running
      }
    )
    #expect(
      fixture.snapshots.values.last?.localAIProviderTest == .passed
    )
    await fixture.runtime.stop()
  }

  /// Discards a provider-test result produced for superseded settings.
  @Test
  func localAISettingsChangeRejectsAStaleProviderTestResult() async throws {
    let fixture = RuntimeFixture(blocksLocalAIProviderTest: true)
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    let testTask = Task {
      await fixture.runtime.testLocalAIProvider()
    }
    try await waitUntil {
      fixture.process.localAIProviderTestIsBlocked
    }
    var settings = LocalAISettings.default
    settings.provider = .ollama

    await fixture.runtime.setLocalAISettings(settings)
    fixture.process.completeLocalAIProviderTest()
    await testTask.value

    #expect(
      fixture.snapshots.values.last?.localAIProviderTest == .idle
    )
    await fixture.runtime.stop()
  }

  /// Cancels current input selection and rebuilds authorized warm resources.
  @Test
  func microphoneSelectionRewarmsTranscription() async throws {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    try await waitUntil {
      fixture.process.warmUpCount == 1
    }

    await fixture.runtime.setPreferredMicrophoneUID("usb-microphone")
    try await waitUntil {
      fixture.process.warmUpCount == 2
        && fixture.snapshots.values.last?
          .transcriptionPrepared == true
    }

    #expect(
      fixture.process.preferredMicrophoneUIDs
        == ["usb-microphone"]
    )
    await fixture.runtime.stop()
  }

  @Test
  func voiceTriggerSettingsReachTheProcessAfterStartup() async {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    let settings = VoiceTriggerSettings(
      shortcut: .suggestedControlActivation
    )

    await fixture.runtime.setVoiceTriggerSettings(settings)

    #expect(
      fixture.process.voiceTriggerSettings == [.default, settings]
    )
    await fixture.runtime.stop()
  }

  /// Keeps typed demo failure separate from synchronous dispatch state.
  @MainActor
  @Test
  func demoTranscriptionFailureDoesNotAddDispatchFailure() {
    let runtime = ApplicationRuntime.make(
      arguments: ["--demo", "--ui-transcription-failure"]
    )

    #expect(runtime.initialSnapshot.transcription.phase == .failed)
    #expect(
      runtime.initialSnapshot.transcription.failure
        == .noFocusedTextField
    )
    #expect(
      runtime.initialSnapshot.runtime.lastActionDispatchSucceeded == nil
    )
  }

  /// Refreshes permission state immediately before process input starts.
  @Test
  func startupUsesLatestAuthoritativeSystemState() async throws {
    let denied = ApplicationSystemState(
      accessibilityTrusted: false,
      microphonePermission: .denied,
      speechRecognitionPermission: .authorized,
      launchAtLogin: false
    )
    let authorized = ApplicationSystemState(
      accessibilityTrusted: true,
      microphonePermission: .authorized,
      speechRecognitionPermission: .authorized,
      launchAtLogin: true
    )
    let fixture = RuntimeFixture(systemState: denied)
    fixture.system.state = authorized

    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    try await waitUntil {
      fixture.snapshots.values.last?
        .transcriptionPrepared == true
    }

    #expect(
      fixture.process.availabilities.last
        == ActionExecutionAvailability(
          dictationAllowed: true,
          keyboardShortcutsAllowed: true
        )
    )
    #expect(
      fixture.snapshots.values.last?.launchAtLogin == true
    )
    await fixture.runtime.stop()
  }

  /// Publishes hot-path snapshots without making the producer await the actor.
  @Test
  func processSnapshotFlowsThroughTheRuntime() async throws {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    let runtimeSnapshot = RuntimeSnapshot(
      devices: [],
      lastDispatchLatencyNanoseconds: 42,
      lastActionDispatchSucceeded: true
    )

    fixture.process.publish(.runtime(runtimeSnapshot))
    try await waitUntil {
      fixture.snapshots.values.last?.runtime == runtimeSnapshot
    }

    await fixture.runtime.stop()
  }

  /// Publishes retry failures as actionable presentation state.
  @Test
  func retryPublishesHardwareFailure() async throws {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    fixture.process.retryResult = .failed(.exclusiveAccess)

    await fixture.runtime.retryHardwareInput()

    #expect(
      fixture.snapshots.values.last?.hardwareInputFailure
        == .exclusiveAccess
    )
    await fixture.runtime.stop()
  }

  /// Suspends active process work and restarts input after wake.
  @Test
  func sleepAndWakeUseRestartableProcessLifecycle() async throws {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    try await waitUntil {
      fixture.process.warmUpCount == 1
    }

    await fixture.runtime.prepareForSleep()
    #expect(
      fixture.snapshots.values.last?
        .transcriptionPrepared == false
    )
    await fixture.runtime.resumeAfterWake()
    try await waitUntil {
      fixture.process.warmUpCount == 2
        && fixture.snapshots.values.last?
          .transcriptionPrepared == true
    }

    #expect(fixture.process.suspendCount == 1)
    #expect(fixture.process.resumeCount == 1)
    #expect(fixture.process.stopCount == 0)
    await fixture.runtime.stop()
  }

  /// Persists login-item state returned by the system adapter.
  @Test
  func launchAtLoginUsesAuthoritativeSystemState() async throws {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )

    await fixture.runtime.setLaunchAtLogin(true)

    #expect(fixture.snapshots.values.last?.launchAtLogin == true)
    #expect(fixture.system.setLaunchValues == [true])
    await fixture.runtime.stop()
  }

  /// Loads durable Profile state before process input begins.
  @Test
  func profileLoadIsAppliedBeforeProcessStart() async throws {
    var envelope = ProfileEnvelope.defaultEnvelope()
    var profile = try #require(envelope.activeProfile)
    let configuration = try #require(
      profile.configuration(
        matching: DeviceMatchRule(modelID: .vecInfinity3)
      )
    )
    var binding = try #require(configuration.binding(for: .left))
    binding.action = .keyboardShortcut(
      KeyboardShortcut(keyCode: 1, modifiers: [.command])
    )
    try profile.setBinding(
      binding,
      configurationID: configuration.id
    )
    envelope.profiles[0] = profile
    let fixture = RuntimeFixture(
      loadedEnvelope: envelope,
      loadsProfileOnStart: true
    )

    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )

    #expect(fixture.process.profiles == [profile])
    #expect(
      fixture.snapshots.values.last?.envelope == envelope
    )
    await fixture.runtime.stop()
  }

  /// Explains that newer Profile data requires an app update.
  @Test
  func newerProfileSchemaNamesUpdateRequirement() async throws {
    let fixture = RuntimeFixture(
      loadedIssue: .requiresNewerApp(
        schemaVersion: ProfileEnvelope.currentSchemaVersion + 1
      ),
      loadsProfileOnStart: true
    )

    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )

    #expect(
      fixture.snapshots.values.last?.recoveryNotice
        == "Your Profiles were created by a newer version of Hardware Controller. Update the app to use them; the saved file was not changed."
    )
    await fixture.runtime.stop()
  }

  /// Creates, renames, and duplicates inactive Profiles without runtime churn.
  @Test
  func inactiveProfileManagementDoesNotReplaceRuntimeProfile() async throws {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )

    await fixture.runtime.createProfile()
    var envelope = try #require(
      fixture.snapshots.values.last?.envelope
    )
    let created = try #require(envelope.profiles.last)
    #expect(created.name == "New Profile")
    #expect(created.deviceConfigurations.isEmpty)

    await fixture.runtime.renameProfile(
      id: created.id,
      name: "  Coding  "
    )
    await fixture.runtime.duplicateProfile(id: created.id)

    envelope = try #require(fixture.snapshots.values.last?.envelope)
    #expect(
      envelope.profiles.map(\.name) == [
        "Default",
        "Coding",
        "Coding Copy",
      ])
    #expect(fixture.process.profiles.isEmpty)
    await fixture.runtime.stop()
  }

  /// Edits an inactive Profile without changing the process resolver.
  @Test
  func inactiveProfileEditDoesNotReplaceRuntimeProfile() async throws {
    let active = Profile.defaultProfile
    let inactive = Profile.safeProfile(
      name: "Music",
      deviceDescriptors: [Infinity3Driver.descriptor]
    )
    let envelope = ProfileEnvelope(
      activeProfileID: active.id,
      profiles: [active, inactive]
    )
    let fixture = RuntimeFixture(
      loadedEnvelope: envelope,
      loadsProfileOnStart: true
    )
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    let configuration = try #require(
      inactive.configuration(
        matching: DeviceMatchRule(modelID: .vecInfinity3)
      )
    )

    await fixture.runtime.setAction(
      .keyboardShortcut,
      for: .left,
      profileID: inactive.id,
      configurationID: configuration.id
    )

    let updated = try #require(
      fixture.snapshots.values.last?.envelope.profile(id: inactive.id)
    )
    #expect(
      updated.binding(
        for: .left,
        matching: DeviceMatchRule(modelID: .vecInfinity3)
      )?.action.kind == .keyboardShortcut
    )
    #expect(fixture.process.profiles == [active])
    #expect(fixture.process.availabilities.count == 1)
    await fixture.runtime.stop()
  }

  /// Persists one opt-in fallback and replaces only the active runtime Profile.
  @Test
  func activeKeyboardFallbackEditIsTransactional() async throws {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    let profile = try #require(
      fixture.snapshots.values.last?.envelope.activeProfile
    )
    let configuration = try #require(
      profile.configuration(
        matching: DeviceMatchRule(modelID: .vecInfinity3)
      )
    )

    await fixture.runtime.setActivationShortcut(
      .suggestedControlActivation,
      for: .center
    )

    let updated = try #require(
      fixture.snapshots.values.last?.envelope.activeProfile?
        .binding(for: .center, matching: configuration.matchRule)
    )
    #expect(
      updated.activationShortcut == .suggestedControlActivation
    )
    #expect(fixture.process.profiles.last?.id == profile.id)
    await fixture.runtime.stop()
  }

  /// Publishes exact-shortcut reservation failures as typed state.
  @Test
  func keyboardFallbackFailureFlowsThroughRuntime() async throws {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    let profile = try #require(
      fixture.snapshots.values.last?.envelope.activeProfile
    )
    let configuration = try #require(profile.deviceConfigurations.first)
    let registration = KeyboardFallbackRegistration(
      targetID: BindingTargetID(
        configurationID: configuration.id,
        controlID: .center
      ),
      sourceDeviceID: DeviceID(rawValue: "keyboard-fallback-test"),
      shortcut: .suggestedControlActivation
    )
    let failure = KeyboardFallbackRegistrationFailure(
      registration: registration,
      systemCode: -1
    )

    fixture.process.publish(.keyboardFallbackFailures([failure]))
    try await waitUntil {
      fixture.snapshots.values.last?.keyboardFallbackFailures == [failure]
    }

    await fixture.runtime.stop()
  }

  @Test
  func voiceShortcutFailureFlowsThroughRuntime() async throws {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    let failure = VoiceShortcutRegistrationFailure(
      shortcut: .suggestedControlActivation,
      systemCode: -1
    )

    fixture.process.publish(.voiceShortcutFailure(failure))
    try await waitUntil {
      fixture.snapshots.values.last?.voiceShortcutFailure == failure
    }

    await fixture.runtime.stop()
  }

  /// Publishes a new active Profile only after the process installs it.
  @Test
  func activationAndActiveDeletionReplaceRuntimeProfile() async throws {
    let active = Profile.defaultProfile
    let music = Profile.safeProfile(
      name: "Music",
      deviceDescriptors: [Infinity3Driver.descriptor]
    )
    let envelope = ProfileEnvelope(
      activeProfileID: active.id,
      profiles: [active, music]
    )
    let fixture = RuntimeFixture(
      loadedEnvelope: envelope,
      loadsProfileOnStart: true
    )
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )

    await fixture.runtime.activateProfile(id: music.id)
    #expect(
      fixture.snapshots.values.last?.envelope.activeProfileID
        == music.id
    )
    #expect(fixture.process.profiles == [active, music])

    await fixture.runtime.deleteProfile(
      id: music.id,
      replacementProfileID: active.id
    )
    #expect(
      fixture.snapshots.values.last?.envelope.profiles == [active]
    )
    #expect(fixture.process.profiles == [active, music, active])
    await fixture.runtime.stop()
  }

  /// Applies active Device-setup removal and restoration transactionally.
  @Test
  func activeDeviceSetupCanBeRemovedAndRestored() async throws {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    let profile = try #require(
      fixture.snapshots.values.last?.envelope.activeProfile
    )
    let configuration = try #require(
      profile.configuration(
        matching: DeviceMatchRule(modelID: .vecInfinity3)
      )
    )

    await fixture.runtime.removeDeviceConfiguration(
      profileID: profile.id,
      configurationID: configuration.id
    )
    #expect(
      fixture.snapshots.values.last?.envelope.activeProfile?
        .deviceConfigurations.isEmpty == true
    )

    await fixture.runtime.addDeviceConfiguration(
      profileID: profile.id,
      descriptor: Infinity3Driver.descriptor
    )
    let restored = try #require(
      fixture.snapshots.values.last?.envelope.activeProfile?
        .configuration(
          matching: DeviceMatchRule(modelID: .vecInfinity3)
        )
    )
    #expect(restored.bindings.allSatisfy { $0.action == .noAction })
    #expect(fixture.process.profiles.count == 2)
    await fixture.runtime.stop()
  }

  /// Keeps active selection unchanged when Profile persistence fails.
  @Test
  func failedProfileActivationIsTransactional() async throws {
    let active = Profile.defaultProfile
    let music = Profile(name: "Music", deviceConfigurations: [])
    let envelope = ProfileEnvelope(
      activeProfileID: active.id,
      profiles: [active, music]
    )
    let fixture = RuntimeFixture(
      profileSaveFails: true,
      loadedEnvelope: envelope,
      loadsProfileOnStart: true
    )
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )

    await fixture.runtime.activateProfile(id: music.id)

    #expect(
      fixture.snapshots.values.last?.envelope.activeProfileID
        == active.id
    )
    #expect(fixture.process.profiles == [active])
    await fixture.runtime.stop()
  }

  /// Keeps a stopped process terminal when start is requested again.
  @Test
  func stoppedRuntimeCannotRestartProcessResources() async {
    let fixture = RuntimeFixture()
    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )
    await fixture.runtime.stop()

    await fixture.runtime.start(
      snapshotHandler: fixture.snapshots.append
    )

    #expect(fixture.process.startCount == 1)
    #expect(fixture.process.stopCount == 1)
  }

  /// Mutates only deterministic state when the system adapter is overridden.
  @Test
  func demoLoginItemChangeNeverCallsTheSystemService() throws {
    let initial = ApplicationSystemState(
      accessibilityTrusted: true,
      microphonePermission: .authorized,
      speechRecognitionPermission: .authorized,
      launchAtLogin: false
    )
    let system = SystemApplicationController(
      stateOverride: initial
    )

    let updated = try system.setLaunchAtLogin(true)

    #expect(updated.launchAtLogin)
    #expect(system.currentState() == updated)
  }
}

@MainActor
private final class RuntimeFixture {
  let process: FakeApplicationProcess
  let system: FakeApplicationSystem
  let snapshots = ApplicationSnapshotRecorder()
  let runtime: ApplicationRuntime

  /// Creates one runtime around deterministic process adapters.
  init(
    profileSaveFails: Bool = false,
    loadedEnvelope: ProfileEnvelope = .defaultEnvelope(),
    loadedIssue: ProfileStoreIssue? = nil,
    loadsProfileOnStart: Bool = false,
    localAIReadiness: LocalAIReadinessSnapshot = .checking,
    blocksLocalAIReadiness: Bool = false,
    blocksLocalAIProviderTest: Bool = false,
    systemState: ApplicationSystemState =
      ApplicationSystemState(
        accessibilityTrusted: true,
        microphonePermission: .authorized,
        speechRecognitionPermission: .authorized,
        launchAtLogin: false
      )
  ) {
    process = FakeApplicationProcess(
      blocksLocalAIReadiness: blocksLocalAIReadiness,
      blocksLocalAIProviderTest: blocksLocalAIProviderTest
    )
    process.localAIReadinessResult = localAIReadiness
    system = FakeApplicationSystem(state: systemState)
    let initial = ApplicationSnapshot(
      envelope: .defaultEnvelope(),
      accessibilityTrusted:
        systemState.accessibilityTrusted,
      microphonePermission:
        systemState.microphonePermission,
      speechRecognitionPermission:
        systemState.speechRecognitionPermission,
      transcription: .idle,
      launchAtLogin: systemState.launchAtLogin
    )
    let process = self.process
    runtime = ApplicationRuntime(
      initialSnapshot: initial,
      isDemoMode: false,
      showsDemoPressedState: false,
      installationLocation: .applications,
      profileStore: MemoryProfileStore(
        loadedEnvelope: loadedEnvelope,
        loadedIssue: loadedIssue,
        saveFails: profileSaveFails
      ),
      system: system,
      loadsProfileOnStart: loadsProfileOnStart,
      processFactory: {
        _,
        _,
        _,
        _,
        _,
        relay in
        process.install(relay)
        return process
      }
    )
  }
}

@MainActor
private final class FakeApplicationSystem:
  ApplicationSystemControlling
{
  var state: ApplicationSystemState
  var requestedState: ApplicationSystemState?
  private(set) var setLaunchValues: [Bool] = []

  /// Stores one deterministic initial system state.
  init(state: ApplicationSystemState) {
    self.state = state
  }

  /// Returns current deterministic system state.
  func currentState() -> ApplicationSystemState {
    state
  }

  /// Applies the configured permission-request result.
  func request(
    _ permission: ApplicationPermission
  ) async -> ApplicationSystemState {
    if let requestedState {
      state = requestedState
    }
    return state
  }

  /// Applies a deterministic login-item registration result.
  func setLaunchAtLogin(
    _ enabled: Bool
  ) throws -> ApplicationSystemState {
    setLaunchValues.append(enabled)
    state = ApplicationSystemState(
      accessibilityTrusted: state.accessibilityTrusted,
      microphonePermission: state.microphonePermission,
      speechRecognitionPermission:
        state.speechRecognitionPermission,
      launchAtLogin: enabled
    )
    return state
  }
}

/// Protects mutable fake process observations with one lock.
private final class FakeApplicationProcess:
  ApplicationProcessControlling,
  @unchecked Sendable
{
  let deviceDescriptor = Infinity3Driver.descriptor

  private let lock = NSLock()
  private var relay: ApplicationProcessEventRelay?
  private var starts = 0
  private var stops = 0
  private var warmUps = 0
  private var suspends = 0
  private var resumes = 0
  private var availabilityStorage: [ActionExecutionAvailability] = []
  private var profileStorage: [Profile] = []
  private var retryStorage = HardwareInputStartResult.started
  private var preferredMicrophoneUIDStorage: [String?] = []
  private var voiceTriggerSettingsStorage: [VoiceTriggerSettings] = []
  private var localAIReadinessStorage = LocalAIReadinessSnapshot.checking
  private var localAIReadinessContinuation: CheckedContinuation<Void, Never>?
  private var localAIReadinessObservers: [CheckedContinuation<Void, Never>] = []
  private let blocksLocalAIReadiness: Bool
  private var localAIProviderTestContinuation: CheckedContinuation<Void, Never>?
  private let blocksLocalAIProviderTest: Bool

  init(
    blocksLocalAIReadiness: Bool,
    blocksLocalAIProviderTest: Bool
  ) {
    self.blocksLocalAIReadiness = blocksLocalAIReadiness
    self.blocksLocalAIProviderTest = blocksLocalAIProviderTest
  }

  var startCount: Int {
    lock.withLock { starts }
  }

  var stopCount: Int {
    lock.withLock { stops }
  }

  var warmUpCount: Int {
    lock.withLock { warmUps }
  }

  var suspendCount: Int {
    lock.withLock { suspends }
  }

  var resumeCount: Int {
    lock.withLock { resumes }
  }

  var availabilities: [ActionExecutionAvailability] {
    lock.withLock { availabilityStorage }
  }

  var profiles: [Profile] {
    lock.withLock { profileStorage }
  }

  var preferredMicrophoneUIDs: [String?] {
    lock.withLock { preferredMicrophoneUIDStorage }
  }

  var voiceTriggerSettings: [VoiceTriggerSettings] {
    lock.withLock { voiceTriggerSettingsStorage }
  }

  var retryResult: HardwareInputStartResult {
    get {
      lock.withLock { retryStorage }
    }
    set {
      lock.withLock { retryStorage = newValue }
    }
  }

  var localAIReadinessResult: LocalAIReadinessSnapshot {
    get { lock.withLock { localAIReadinessStorage } }
    set { lock.withLock { localAIReadinessStorage = newValue } }
  }

  var localAIProviderTestIsBlocked: Bool {
    lock.withLock { localAIProviderTestContinuation != nil }
  }

  /// Waits until readiness is blocked after hardware startup completes.
  func waitUntilLocalAIReadinessIsBlocked() async {
    await withCheckedContinuation { observer in
      let shouldResume = lock.withLock {
        guard localAIReadinessContinuation == nil else {
          return true
        }
        localAIReadinessObservers.append(observer)
        return false
      }
      if shouldResume {
        observer.resume()
      }
    }
  }

  /// Resumes a deliberately blocked readiness request.
  func completeLocalAIReadiness() {
    let continuation = lock.withLock {
      let continuation = localAIReadinessContinuation
      localAIReadinessContinuation = nil
      return continuation
    }
    continuation?.resume()
  }

  /// Resumes a deliberately blocked provider test.
  func completeLocalAIProviderTest() {
    let continuation = lock.withLock {
      let continuation = localAIProviderTestContinuation
      localAIProviderTestContinuation = nil
      return continuation
    }
    continuation?.resume()
  }

  /// Installs the process event relay supplied by the runtime.
  func install(
    _ relay: ApplicationProcessEventRelay
  ) {
    lock.withLock {
      self.relay = relay
    }
  }

  /// Records one process start.
  func start() -> HardwareInputStartResult {
    lock.withLock {
      starts += 1
    }
    return .started
  }

  /// Records one complete process stop.
  func stop() async {
    lock.withLock {
      stops += 1
    }
  }

  /// Records one restartable process suspension.
  func suspend() async {
    lock.withLock {
      suspends += 1
    }
  }

  /// Records one hardware-input restart.
  func resume() -> HardwareInputStartResult {
    lock.withLock {
      resumes += 1
    }
    return .started
  }

  /// Returns the currently configured retry result.
  func retryHardwareInput() -> HardwareInputStartResult {
    retryResult
  }

  /// Records each Profile published after persistence.
  func setProfile(_ profile: Profile) async {
    lock.withLock {
      profileStorage.append(profile)
    }
  }

  /// Records each permission-derived Action availability.
  func setAvailability(
    _ availability: ActionExecutionAvailability
  ) {
    lock.withLock {
      availabilityStorage.append(availability)
    }
  }

  /// Records one successful transcription warm-up.
  func warmUpTranscription() async -> TranscriptionFailure? {
    lock.withLock {
      warmUps += 1
    }
    return nil
  }

  /// Records each app-local microphone selection.
  func setPreferredMicrophoneUID(_ uniqueID: String?) async {
    lock.withLock {
      preferredMicrophoneUIDStorage.append(uniqueID)
    }
  }

  /// Accepts Local AI settings and returns deterministic readiness.
  func setLocalAISettings(
    _ settings: LocalAISettings,
    profileName: String
  ) async -> LocalAIReadinessSnapshot {
    return localAIReadinessResult
  }

  /// Records each independent Voice trigger configuration.
  func setVoiceTriggerSettings(
    _ settings: VoiceTriggerSettings
  ) async throws -> VoiceShortcutRegistrationFailure? {
    lock.withLock {
      voiceTriggerSettingsStorage.append(settings)
    }
    return nil
  }

  /// Returns deterministic provider readiness without external processes.
  func localAIReadiness() async -> LocalAIReadinessSnapshot {
    if blocksLocalAIReadiness {
      await withCheckedContinuation { continuation in
        let observers = lock.withLock {
          localAIReadinessContinuation = continuation
          let observers = localAIReadinessObservers
          localAIReadinessObservers.removeAll()
          return observers
        }
        for observer in observers {
          observer.resume()
        }
      }
    }
    return localAIReadinessResult
  }

  /// Passes the deterministic sanitized provider test.
  func testLocalAIProvider() async -> LocalAIRefinementFailure? {
    if blocksLocalAIProviderTest {
      await withCheckedContinuation { continuation in
        lock.withLock {
          localAIProviderTestContinuation = continuation
        }
      }
    }
    return nil
  }

  /// Accepts a deterministic test request.
  func testBinding(_ controlID: ControlID) {}

  /// Accepts a deterministic demo transition.
  func simulate(
    _ controlID: ControlID,
    phase: ControlPhase
  ) {}

  /// Publishes one process event through the production relay.
  func publish(
    _ event: ApplicationProcessEventRelay.Event
  ) {
    let relay = lock.withLock { self.relay }
    switch event {
    case .runtime(let snapshot):
      relay?.publishRuntime(snapshot)
    case .transcription(let snapshot):
      relay?.publishTranscription(snapshot)
    case .localAIDictation(let snapshot):
      relay?.publishLocalAIDictation(snapshot)
    case .keyboardFallbackFailures(let failures):
      relay?.publishKeyboardFallbackFailures(failures)
    case .voiceShortcutFailure(let failure):
      relay?.publishVoiceShortcutFailure(failure)
    }
  }
}

private struct MemoryProfileStore: ProfilePersisting {
  let loadedEnvelope: ProfileEnvelope
  let loadedIssue: ProfileStoreIssue?
  let saveFails: Bool

  /// Returns the configured Profile for deterministic tests.
  func load() -> ProfileLoadResult {
    ProfileLoadResult(
      envelope: loadedEnvelope,
      issue: loadedIssue
    )
  }

  /// Optionally simulates an atomic persistence failure.
  func save(_ envelope: ProfileEnvelope) throws {
    if saveFails {
      throw MemoryProfileStoreError.couldNotWrite
    }
  }
}

private enum MemoryProfileStoreError: Error {
  case couldNotWrite
}

/// Protects immutable snapshot observations with one lock.
private final class ApplicationSnapshotRecorder:
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storage: [ApplicationSnapshot] = []

  var values: [ApplicationSnapshot] {
    lock.withLock { storage }
  }

  /// Appends one immutable application snapshot.
  func append(_ snapshot: ApplicationSnapshot) {
    lock.withLock {
      storage.append(snapshot)
    }
  }
}

@MainActor
/// Waits for an asynchronously published runtime condition.
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
  Issue.record("Timed out waiting for application state.")
}
