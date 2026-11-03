import Foundation
import HardwareControllerCore
import HardwareControllerMac

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

  /// Selects the speech engine and its package for every later session.
  func setSpeechEngineConfiguration(_ configuration: SpeechEngineConfiguration) async

  /// Reconfigures Local AI Dictation and returns provider readiness.
  func setLocalAISettings(
    _ settings: LocalAISettings,
    profileName: String
  ) async -> LocalAIReadinessSnapshot

  /// Replaces the independent Voice chord and reports a reservation conflict.
  func setVoiceTriggerSettings(
    _ settings: VoiceTriggerSettings
  ) async throws -> VoiceShortcutRegistrationFailure?

  /// Returns current local provider and model readiness.
  func localAIReadiness() async -> LocalAIReadinessSnapshot

  /// Runs a sanitized generation test without microphone or target access.
  func testLocalAIProvider() async -> LocalAIRefinementFailure?

  /// Submits one app-initiated command to the shared Voice dispatcher.
  func submitVoiceCapture(_ command: DictationCommand) -> Bool

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
    case voiceShortcutFailure(VoiceShortcutRegistrationFailure?)
    case speechEngineFallback(SpeechEngineFallbackReason)
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

  /// Announces that a session fell back to Apple; never silent (docs/decisions/asr_runtime.md).
  func publishSpeechEngineFallback(_ reason: SpeechEngineFallbackReason) {
    let handler = lock.withLock { self.handler }
    handler?(.speechEngineFallback(reason))
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

  /// Publishes the independent Voice chord reservation outcome.
  func publishVoiceShortcutFailure(
    _ failure: VoiceShortcutRegistrationFailure?
  ) {
    let handler = lock.withLock { self.handler }
    handler?(.voiceShortcutFailure(failure))
  }
}
