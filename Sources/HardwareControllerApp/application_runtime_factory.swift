import Foundation
import HardwareControllerCore
import HardwareControllerMac
import ServiceManagement

extension ApplicationRuntime {
  /// Creates the complete live or deterministic demo application runtime.
  @MainActor
  static func make(
    arguments: [String],
    profileStore providedProfileStore:
      (any ProfilePersisting)? = nil,
    preferredMicrophoneUID: String? = nil,
    localAISettings: LocalAISettings = .default,
    speechEngine: SpeechEngineConfiguration = .unconfigured,
    voiceTriggerSettings: VoiceTriggerSettings = .default,
    voiceSessionHistory: (any VoiceSessionHistoryRecording)? = nil
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
      localAIStyle: localAISettings.style,
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
      speechEngine: speechEngine,
      voiceTriggerSettings: voiceTriggerSettings,
      voiceSessionHistory: voiceSessionHistory,
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
