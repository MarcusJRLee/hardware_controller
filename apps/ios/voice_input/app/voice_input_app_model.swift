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
  @Published private(set) var lifecycleMessage: String?

  private let onboardingPolicy = VoiceInputOnboardingPolicy()
  private let lifecycleNotificationMapper = VoiceInputLifecycleNotificationMapper()
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
        captureDirectoryURL: documentsURL,
        controlReloader: VoiceInputSystemControlReloader.reload
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
      do {
        try await service?.reconcileOnActivation()
      } catch {
        errorMessage = "The previous local capture state could not be recovered."
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
    lifecycleMessage = nil
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
    guard let event = lifecycleNotificationMapper.audioInterruption(notification) else {
      return
    }
    handleLifecycleEvent(event)
  }

  func handleRouteChange(_ notification: Notification) {
    guard let event = lifecycleNotificationMapper.audioRouteChange(notification) else {
      return
    }
    handleLifecycleEvent(event)
  }

  func handleLifecycleEvent(_ event: VoiceInputLifecycleEvent) {
    Task {
      await applyLifecycleEvent(event)
    }
  }

  func applyLifecycleEvent(_ event: VoiceInputLifecycleEvent) async {
    guard let service else {
      return
    }
    let decision = await service.handleLifecycleEvent(event)
    switch decision {
    case .ignore:
      break
    case .continueCapture(let advisory):
      lifecycleMessage = advisory?.message
    case .interrupt(let reason):
      lifecycleMessage = reason.message
    }
    await refresh()
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

extension VoiceInputLifecycleAdvisory {
  fileprivate var message: String {
    switch self {
    case .audioRouteChanged:
      "The system changed the audio route. Local recording continues on the confirmed route."
    case .backgroundRecording:
      "Recording continues in the background with a visible Live Activity."
    case .lowPowerMode:
      "Low Power Mode is active. Recording remains local and continues."
    case .thermalPressure:
      "The iPhone is warm. Recording continues, but finalization may be slower."
    }
  }
}

extension VoiceInputCaptureInterruptionReason {
  fileprivate var message: String {
    switch self {
    case .audioInterruption:
      "An audio interruption stopped capture. The partial recording is in History."
    case .audioRouteChange:
      "An audio route change stopped capture. The partial recording is in History."
    case .mediaServicesUnavailable:
      "iOS audio services stopped capture. The partial recording is in History."
    case .backgroundOwnershipUnavailable:
      "Capture stopped because no visible Live Activity owned background recording. The partial recording is in History."
    case .backgroundExecutionExpired:
      "iOS ended background finalization. The partial recording is in History."
    case .thermalPressure:
      "Critical thermal pressure stopped capture. The partial recording is in History."
    case .processTermination:
      "A previous capture ended unexpectedly. Its partial recording is in History."
    case .finalizationFailure:
      "Finalization failed. The recoverable recording remains in History."
    }
  }
}
