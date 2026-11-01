import Foundation
import HardwareControllerCore
import HardwareControllerMac

typealias LiveActionExecutor = MacActionExecutor<
  CoreGraphicsKeyboardEventPoster
>
typealias LiveControllerRuntime = ControllerRuntime<LiveActionExecutor>

/// Owns queue- or actor-isolated process seams behind a Sendable interface.
final class LiveApplicationProcess:
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
  private let voiceDictationDispatcher: any DictationCommandDispatching
  private let eventRelay: ApplicationProcessEventRelay
  private var profile: Profile
  private var localAISettings: LocalAISettings
  private var voiceTriggerSettings: VoiceTriggerSettings = .default
  private var voiceKeyboardTriggerController: VoiceKeyboardTriggerController?
  private var keyboardFallbackInputSource: KeyboardFallbackInputSource?
  private var isRunning = false

  /// Composes all live adapters while keeping their details behind one interface.
  init(
    profile: Profile,
    isDemoMode: Bool,
    showsDemoPressedState: Bool,
    preferredMicrophoneUID: String?,
    localAISettings: LocalAISettings,
    voiceSessionHistory providedHistory:
      (any VoiceSessionHistoryRecording)?,
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

    let history: any VoiceSessionHistoryRecording
    if let providedHistory {
      history = providedHistory
    } else {
      do {
        history = try SQLiteVoiceSessionHistory.applicationSupportHistory()
      } catch let failure as VoiceSessionHistoryError {
        history = UnavailableVoiceSessionHistory(failure: failure)
      } catch {
        history = UnavailableVoiceSessionHistory(
          failure: .storageUnavailable(
            "Voice History could not open its local storage."
          )
        )
      }
    }

    let localAIDictationController = LocalAIDictationController(
      factory: sessionFactory,
      microphone: microphone,
      targeter: targeter,
      writer: writer,
      authorization: SystemTranscriptionAuthorizationProvider(),
      settings: localAISettings,
      profileName: profile.name,
      history: history,
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
    voiceDictationDispatcher = localAIDispatcher

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
    await registerKeyboardInputs()
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
    await registerKeyboardInputs()
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
      await voiceKeyboardTriggerController?.interrupt()
      await registerKeyboardInputs()
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

  /// Replaces the Voice state machine before changing its exact global chord.
  func setVoiceTriggerSettings(
    _ settings: VoiceTriggerSettings
  ) async throws -> VoiceShortcutRegistrationFailure? {
    await voiceKeyboardTriggerController?.interrupt()
    voiceKeyboardTriggerController = try VoiceKeyboardTriggerController(
      settings: settings,
      dispatcher: voiceDictationDispatcher
    )
    voiceTriggerSettings = settings
    guard isRunning else {
      return nil
    }
    return await registerKeyboardInputs().voiceFailure
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

  /// Uses the same Local AI dispatcher as Controls and the Voice chord.
  func submitVoiceCapture(_ command: DictationCommand) -> Bool {
    guard isRunning else {
      return false
    }
    return voiceDictationDispatcher.submit(command)
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

  /// Reserves Binding fallbacks and the Voice chord on one main event target.
  @discardableResult
  private func registerKeyboardInputs() async
    -> KeyboardInputRegistrationResult
  {
    let registrations = ProfileBindingResolver(
      profile: profile
    ).keyboardFallbacks
    let runtime = self.runtime
    let voiceController = voiceKeyboardTriggerController
    let voiceShortcut = voiceTriggerSettings.shortcut
    let result = await MainActor.run {
      keyboardFallbackInputSource?.stop()
      let source = KeyboardFallbackInputSource(
        onEvent: { registration, phase, timestamp in
          runtime.handleKeyboardFallback(
            registration,
            phase: phase,
            timestampNanoseconds: timestamp
          )
        },
        onVoiceEvent: { phase, timestamp in
          Task {
            await voiceController?.handle(
              phase: phase,
              timestampNanoseconds: timestamp
            )
          }
        }
      )
      keyboardFallbackInputSource = source
      return source.replace(
        fallbacks: registrations,
        voiceShortcut: voiceShortcut
      )
    }
    eventRelay.publishKeyboardFallbackFailures(result.fallbackFailures)
    eventRelay.publishVoiceShortcutFailure(result.voiceFailure)
    return result
  }

  /// Releases global shortcuts before sleep or process shutdown.
  private func stopKeyboardFallbacks() async {
    await voiceKeyboardTriggerController?.interrupt()
    await MainActor.run {
      keyboardFallbackInputSource?.stop()
      keyboardFallbackInputSource = nil
    }
    eventRelay.publishKeyboardFallbackFailures([])
    eventRelay.publishVoiceShortcutFailure(nil)
  }
}

/// Accepts demo Dictation commands without starting system work.
struct PreviewDictationCommandDispatcher:
  DictationCommandDispatching
{
  /// Accepts every deterministic preview command.
  func submit(_ command: DictationCommand) -> Bool {
    true
  }

  /// Has no process resources to release.
  func shutdown() {}
}
