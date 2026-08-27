import AVFAudio
import Combine
import Foundation
import VoiceInputShared

@MainActor
final class VoiceInputAppModel: ObservableObject {
  @Published private(set) var snapshot = VoiceInputSnapshot.idle(sequence: 0)
  @Published private(set) var errorMessage: String?
  @Published private(set) var snapshotErrorMessage: String?
  @Published private(set) var onboardingErrorMessage: String?
  @Published private(set) var microphoneAuthorization: VoiceInputMicrophoneAuthorization
  @Published private(set) var keyboardHandoffObserved = false
  @Published private(set) var selectedStyleKind: VoiceInputStyleKind

  private let onboardingPolicy = VoiceInputOnboardingPolicy()
  private let microphoneAuthorizationProvider:
    @MainActor @Sendable () -> VoiceInputMicrophoneAuthorization
  private let microphonePermissionRequester: @MainActor @Sendable () async -> Bool
  private let keyboardObservedAtReader: @Sendable () throws -> Date?
  private let styleWriter: @MainActor (VoiceInputStyleKind) -> Void
  private let service: (any VoiceInputCapturing)?
  private var refreshTask: Task<Void, Never>?

  convenience init() {
    let store = VoiceInputKeychainStore()
    let service: (any VoiceInputCapturing)?
    if let documentsURL = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first {
      service = VoiceInputCaptureService(
        store: store,
        captureURL: documentsURL.appendingPathComponent("voice_input_capture.caf")
      )
    } else {
      service = nil
    }
    self.init(
      microphoneAuthorizationProvider: { Self.systemMicrophoneAuthorization },
      microphonePermissionRequester: {
        await AVAudioApplication.requestRecordPermission()
      },
      keyboardObservedAtReader: { try store.readKeyboardObservedAt() },
      service: service,
      initialStyleKind: Self.storedAppStyleKind,
      styleWriter: Self.persistAppStyle
    )
    if service == nil {
      errorMessage = "The local app container is unavailable."
    }
  }

  convenience init(
    store: VoiceInputKeychainStore,
    service: (any VoiceInputCapturing)?
  ) {
    self.init(
      microphoneAuthorizationProvider: { Self.systemMicrophoneAuthorization },
      microphonePermissionRequester: {
        await AVAudioApplication.requestRecordPermission()
      },
      keyboardObservedAtReader: { try store.readKeyboardObservedAt() },
      service: service,
      initialStyleKind: Self.storedAppStyleKind,
      styleWriter: Self.persistAppStyle
    )
    if service == nil {
      errorMessage = "The local app container is unavailable."
    }
  }

  init(
    microphoneAuthorizationProvider:
      @escaping @MainActor @Sendable () ->
      VoiceInputMicrophoneAuthorization,
    microphonePermissionRequester: @escaping @MainActor @Sendable () async -> Bool,
    keyboardObservedAtReader: @escaping @Sendable () throws -> Date?,
    service: (any VoiceInputCapturing)? = nil,
    initialStyleKind: VoiceInputStyleKind = .natural,
    styleWriter: @escaping @MainActor (VoiceInputStyleKind) -> Void = { _ in }
  ) {
    self.microphoneAuthorizationProvider = microphoneAuthorizationProvider
    self.microphonePermissionRequester = microphonePermissionRequester
    self.keyboardObservedAtReader = keyboardObservedAtReader
    self.styleWriter = styleWriter
    self.service = service
    microphoneAuthorization = microphoneAuthorizationProvider()
    selectedStyleKind = initialStyleKind
  }

  var isRecording: Bool {
    snapshot.phase == .recording
  }

  var onboardingStep: VoiceInputOnboardingStep {
    onboardingPolicy.nextStep(
      microphone: microphoneAuthorization,
      keyboardHandoffObserved: keyboardHandoffObserved
    )
  }

  var canCapture: Bool {
    microphoneAuthorization == .authorized
  }

  func activate() {
    guard refreshTask == nil else {
      return
    }
    refreshTask = Task { [weak self] in
      guard let self else {
        return
      }
      while !Task.isCancelled {
        await processPendingCommand()
        await refresh()
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  func deactivate() {
    refreshTask?.cancel()
    refreshTask = nil
  }

  func start() {
    perform { service in
      try await service.start(sessionID: UUID())
    }
  }

  func requestMicrophone() {
    Task {
      await applyMicrophoneRequest()
    }
  }

  func applyMicrophoneRequest() async {
    let granted = await microphonePermissionRequester()
    microphoneAuthorization = granted ? .authorized : .denied
  }

  func stop() {
    let styleKind = selectedStyleKind
    Task {
      await applyStop(styleKind: styleKind)
    }
  }

  func applyStop() async {
    await applyStop(styleKind: selectedStyleKind)
  }

  private func applyStop(styleKind: VoiceInputStyleKind) async {
    guard let service else {
      return
    }
    errorMessage = nil
    do {
      try await service.stop(styleKind: styleKind)
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func selectStyle(_ styleKind: VoiceInputStyleKind) {
    selectedStyleKind = styleKind
    styleWriter(styleKind)
  }

  func handleInterruption(_ notification: Notification) {
    guard
      let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      AVAudioSession.InterruptionType(rawValue: rawValue) == .began
    else {
      return
    }
    guard let service else {
      return
    }
    Task {
      await service.interrupt()
      await refresh()
    }
  }

  private func processPendingCommand() async {
    guard let service else {
      return
    }
    do {
      try await service.processPendingCommand()
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func refresh() async {
    refreshOnboarding()
    guard let service else {
      return
    }
    do {
      snapshot = try await service.snapshot()
      snapshotErrorMessage = nil
    } catch {
      snapshotErrorMessage = "The local capture state is unavailable."
    }
  }

  func refreshOnboarding() {
    microphoneAuthorization = microphoneAuthorizationProvider()
    do {
      keyboardHandoffObserved = try keyboardObservedAtReader() != nil
      onboardingErrorMessage = nil
    } catch {
      keyboardHandoffObserved = false
      onboardingErrorMessage =
        "The local keyboard handoff is unavailable. Close and reopen the app and keyboard."
    }
  }

  private static var systemMicrophoneAuthorization: VoiceInputMicrophoneAuthorization {
    switch AVAudioApplication.shared.recordPermission {
    case .undetermined:
      return .undetermined
    case .denied:
      return .denied
    case .granted:
      return .authorized
    @unknown default:
      return .denied
    }
  }

  private static var storedAppStyleKind: VoiceInputStyleKind {
    appStylePreference.read()
  }

  private static func persistAppStyle(_ styleKind: VoiceInputStyleKind) {
    appStylePreference.write(styleKind)
  }

  private static var appStylePreference: VoiceInputStylePreferenceStore {
    VoiceInputStylePreferenceStore(
      key: VoiceInputEnvironment.appStyleKindKey
    )
  }

  private func perform(
    _ operation: @escaping @Sendable (any VoiceInputCapturing) async throws -> Void
  ) {
    guard let service else {
      return
    }
    errorMessage = nil
    Task {
      do {
        try await operation(service)
        await refresh()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
