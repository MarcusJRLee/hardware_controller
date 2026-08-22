import AppKit
import Foundation
import HardwareControllerCore
import HardwareControllerMac
import Observation

/// Presents immutable application runtime state to SwiftUI.
@MainActor
@Observable
final class AppModel {
  private(set) var applicationSnapshot: ApplicationSnapshot

  let isDemoMode: Bool
  let showsDemoPressedState: Bool
  let installationLocation: ApplicationInstallationLocation

  @ObservationIgnored private let runtime: ApplicationRuntime
  @ObservationIgnored private let focusedTextTargeter =
    AccessibilityFocusedTextTargeting()
  @ObservationIgnored private let transcriptionIndicator =
    TranscriptionIndicatorController()
  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var intentTask: Task<Void, Never>?
  @ObservationIgnored private var providerTestTask: Task<Void, Never>?
  @ObservationIgnored private var isStarted = false

  /// Creates presentation around one deep application runtime interface.
  init(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    profileStore: (any ProfilePersisting)? = nil,
    preferredMicrophoneUID: String? = nil,
    localAISettings: LocalAISettings = .default
  ) {
    let runtime = ApplicationRuntime.make(
      arguments: arguments,
      profileStore: profileStore,
      preferredMicrophoneUID: preferredMicrophoneUID,
      localAISettings: localAISettings
    )
    self.runtime = runtime
    applicationSnapshot = runtime.initialSnapshot
    isDemoMode = runtime.isDemoMode
    showsDemoPressedState = runtime.showsDemoPressedState
    installationLocation = runtime.installationLocation
  }

  var envelope: ProfileEnvelope {
    applicationSnapshot.envelope
  }

  var runtimeSnapshot: RuntimeSnapshot {
    applicationSnapshot.runtime
  }

  var accessibilityTrusted: Bool {
    applicationSnapshot.accessibilityTrusted
  }

  var microphonePermission: PermissionStatus {
    applicationSnapshot.microphonePermission
  }

  var speechRecognitionPermission: PermissionStatus {
    applicationSnapshot.speechRecognitionPermission
  }

  var transcriptionSnapshot: TranscriptionSnapshot {
    applicationSnapshot.transcription
  }

  var localAIDictationSnapshot: LocalAIDictationSnapshot {
    applicationSnapshot.localAIDictation
  }

  var localAIReadiness: LocalAIReadinessSnapshot {
    applicationSnapshot.localAIReadiness
  }

  var selectedLocalAIReadiness: LocalAIProviderReadiness {
    localAIReadiness.readiness(for: applicationSnapshot.localAIProvider)
  }

  var localAIProviderTest: LocalAIProviderTestState {
    applicationSnapshot.localAIProviderTest
  }

  var transcriptionPrepared: Bool {
    applicationSnapshot.transcriptionPrepared
  }

  var transcriptionPreparationFailure: TranscriptionFailure? {
    applicationSnapshot.transcriptionPreparationFailure
  }

  var launchAtLogin: Bool {
    applicationSnapshot.launchAtLogin
  }

  var hardwareInputFailure: HardwareInputStartFailure? {
    applicationSnapshot.hardwareInputFailure
  }

  var keyboardFallbackFailures: [KeyboardFallbackRegistrationFailure] {
    applicationSnapshot.keyboardFallbackFailures
  }

  var lastError: String? {
    applicationSnapshot.lastError
  }

  var recoveryNotice: String? {
    applicationSnapshot.recoveryNotice
  }

  var activeProfile: Profile {
    envelope.activeProfile ?? .defaultProfile
  }

  var profiles: [Profile] {
    envelope.profiles
  }

  var connectedDevices: [ConnectedDeviceSnapshot] {
    runtimeSnapshot.devices
  }

  var defaultDeviceDescriptor: DeviceModelDescriptor {
    runtime.deviceDescriptor
  }

  var supportedDeviceDescriptors: [DeviceModelDescriptor] {
    var modelIDs: Set<DeviceModelID> = []
    let connectedDescriptors = connectedDevices.map(\.model)
    let descriptors =
      connectedDescriptors.isEmpty
      ? [defaultDeviceDescriptor] : connectedDescriptors
    return descriptors.filter {
      modelIDs.insert($0.modelID).inserted
    }
  }

  var isConnected: Bool {
    !connectedDevices.isEmpty
  }

  var hardwareInputMessage: String? {
    hardwareInputFailure?.recoveryMessage
  }

  var requiresInstallation: Bool {
    installationLocation.requiresInstallation
  }

  var canManageLaunchAtLogin: Bool {
    installationLocation.canRegisterLoginItem
  }

  var hasConfiguredAction: Bool {
    activeBindings.contains {
      $0.action.kind != .noAction
    }
  }

  var hasBlockedConfiguredAction: Bool {
    activeBindings.contains {
      $0.action.kind != .noAction
        && !canExecute($0.action.kind)
    }
  }

  var hasDictationAction: Bool {
    activeBindings.contains {
      $0.action.kind.ownsDictationSession
    }
  }

  var hasLocalDictationAction: Bool {
    activeBindings.contains { $0.action.kind == .dictation }
  }

  var hasLocalAIAction: Bool {
    activeBindings.contains { $0.action.kind == .localAIDictation }
  }

  var hasLegacyDictationShortcut: Bool {
    !hasDictationAction
      && activeBindings.contains { binding in
        binding.action.kind == .keyboardShortcut
          && binding.action.shortcut?.modifiers
            .isSuperset(of: [.control, .option]) == true
      }
  }

  var canExecuteActions: Bool {
    canExecuteDictation || canExecuteKeyboardShortcuts
  }

  var canExecuteDictation: Bool {
    !requiresInstallation
      && accessibilityTrusted
      && microphonePermission == .authorized
      && speechRecognitionPermission == .authorized
  }

  var canExecuteKeyboardShortcuts: Bool {
    !requiresInstallation && accessibilityTrusted
  }

  var canExecuteLocalAIDictation: Bool {
    canExecuteDictation && selectedLocalAIReadiness.state.canRun
  }

  /// Reports whether one configured Action can currently execute.
  func canExecute(_ kind: ActionKind) -> Bool {
    switch kind {
    case .noAction:
      true
    case .dictation:
      canExecuteDictation
    case .localAIDictation:
      canExecuteLocalAIDictation
    case .keyboardShortcut:
      canExecuteKeyboardShortcuts
    }
  }

  var actionDispatchFailed: Bool {
    runtimeSnapshot.lastActionDispatchSucceeded == false
  }

  var isAnyActionActive: Bool {
    runtimeSnapshot.hasActiveActions
  }

  var isTranscriptionActive: Bool {
    [.preparing, .listening, .finalizing, .canceling]
      .contains(transcriptionSnapshot.phase)
      || [
        .preparing,
        .listening,
        .finalizing,
        .refining,
        .validating,
        .delivering,
        .canceling,
      ].contains(localAIDictationSnapshot.phase)
  }

  var latencyText: String? {
    guard
      let nanoseconds = runtimeSnapshot
        .lastDispatchLatencyNanoseconds
    else {
      return nil
    }
    return String(
      format: "%.2f ms",
      Double(nanoseconds) / 1_000_000
    )
  }

  /// Starts presentation and application orchestration once.
  func start() {
    guard !isStarted else {
      return
    }
    isStarted = true
    transcriptionIndicator.start()
    refreshTranscriptionIndicator()

    startTask = Task { [runtime] in
      guard !Task.isCancelled else {
        return
      }
      await runtime.start { [weak self] snapshot in
        Task { @MainActor [weak self] in
          self?.applicationSnapshot = snapshot
          self?.refreshTranscriptionIndicator()
        }
      }
    }
  }

  /// Stops presentation and waits for all process cleanup.
  func stop() async {
    guard isStarted else {
      return
    }
    isStarted = false
    transcriptionIndicator.stop()
    startTask?.cancel()
    await startTask?.value
    startTask = nil
    providerTestTask?.cancel()
    await providerTestTask?.value
    providerTestTask = nil
    await intentTask?.value
    intentTask = nil
    await runtime.stop()
  }

  /// Joins current presentation intents, then yields to snapshot delivery.
  func waitForPendingIntents() async {
    await intentTask?.value
    await Task.yield()
  }

  /// Ends active process work before system sleep.
  func prepareForSleep() async {
    await runtime.prepareForSleep()
  }

  /// Restarts hardware input after system wake.
  func resumeAfterWake() {
    enqueueIntent { [runtime] in
      await runtime.resumeAfterWake()
    }
  }

  /// Retries the hardware-input adapter.
  func retryHardwareInput() {
    enqueueIntent { [runtime] in
      await runtime.retryHardwareInput()
    }
  }

  /// Returns a configured Binding or its conservative default.
  func binding(for controlID: ControlID) -> Binding {
    binding(
      for: controlID,
      matching: DeviceMatchRule(
        modelID: defaultDeviceDescriptor.modelID
      )
    )
  }

  /// Returns one active Binding through a Device match identity.
  func binding(
    for controlID: ControlID,
    matching device: DeviceMatchRule
  ) -> Binding {
    activeProfile.binding(
      for: controlID,
      matching: device
    )
      ?? Binding(
        controlID: controlID,
        interactionMode: .momentary,
        action: .noAction
      )
  }

  /// Returns one Profile setup Binding or its conservative default.
  func binding(
    for controlID: ControlID,
    profileID: UUID,
    configurationID: UUID
  ) -> Binding {
    envelope.profile(id: profileID)?
      .deviceConfigurations.first {
        $0.id == configurationID
      }?
      .binding(for: controlID)
      ?? Binding(
        controlID: controlID,
        interactionMode: .momentary,
        action: .noAction
      )
  }

  /// Returns every Binding in the active work mode.
  private var activeBindings: [Binding] {
    activeProfile.deviceConfigurations.flatMap(\.bindings)
  }

  /// Requests a transactional Action change.
  func setAction(
    _ kind: ActionKind,
    for controlID: ControlID
  ) {
    enqueueIntent { [runtime] in
      await runtime.setAction(kind, for: controlID)
    }
  }

  /// Requests a transactional interaction-mode change.
  func setInteractionMode(
    _ mode: InteractionMode,
    for controlID: ControlID
  ) {
    enqueueIntent { [runtime] in
      await runtime.setInteractionMode(mode, for: controlID)
    }
  }

  /// Requests a transactional keyboard-shortcut change.
  func setShortcut(
    _ shortcut: KeyboardShortcut,
    for controlID: ControlID
  ) {
    enqueueIntent { [runtime] in
      await runtime.setShortcut(shortcut, for: controlID)
    }
  }

  /// Requests a transactional keyboard-fallback change.
  func setActivationShortcut(
    _ shortcut: KeyboardShortcut?,
    for controlID: ControlID
  ) {
    enqueueIntent { [runtime] in
      await runtime.setActivationShortcut(
        shortcut,
        for: controlID
      )
    }
  }

  /// Requests one Action change in an identified Profile setup.
  func setAction(
    _ kind: ActionKind,
    for controlID: ControlID,
    profileID: UUID,
    configurationID: UUID
  ) {
    enqueueIntent { [runtime] in
      await runtime.setAction(
        kind,
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    }
  }

  /// Requests one mode change in an identified Profile setup.
  func setInteractionMode(
    _ mode: InteractionMode,
    for controlID: ControlID,
    profileID: UUID,
    configurationID: UUID
  ) {
    enqueueIntent { [runtime] in
      await runtime.setInteractionMode(
        mode,
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    }
  }

  /// Requests one shortcut change in an identified Profile setup.
  func setShortcut(
    _ shortcut: KeyboardShortcut,
    for controlID: ControlID,
    profileID: UUID,
    configurationID: UUID
  ) {
    enqueueIntent { [runtime] in
      await runtime.setShortcut(
        shortcut,
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    }
  }

  /// Requests one fallback change in an identified Profile setup.
  func setActivationShortcut(
    _ shortcut: KeyboardShortcut?,
    for controlID: ControlID,
    profileID: UUID,
    configurationID: UUID
  ) {
    enqueueIntent { [runtime] in
      await runtime.setActivationShortcut(
        shortcut,
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    }
  }

  /// Returns an active fallback reservation failure for one Binding.
  func keyboardFallbackFailure(
    for controlID: ControlID,
    configurationID: UUID
  ) -> KeyboardFallbackRegistrationFailure? {
    keyboardFallbackFailures.first {
      $0.registration.targetID
        == BindingTargetID(
          configurationID: configurationID,
          controlID: controlID
        )
    }
  }

  /// Creates one safely inactive Profile.
  func createProfile() {
    enqueueIntent { [runtime] in
      await runtime.createProfile()
    }
  }

  /// Duplicates one complete Profile without activating it.
  func duplicateProfile(id: UUID) {
    enqueueIntent { [runtime] in
      await runtime.duplicateProfile(id: id)
    }
  }

  /// Renames one Profile transactionally.
  func renameProfile(id: UUID, name: String) {
    enqueueIntent { [runtime] in
      await runtime.renameProfile(id: id, name: name)
    }
  }

  /// Deletes one Profile with an explicit active replacement.
  func deleteProfile(
    id: UUID,
    replacementProfileID: UUID?
  ) {
    enqueueIntent { [runtime] in
      await runtime.deleteProfile(
        id: id,
        replacementProfileID: replacementProfileID
      )
    }
  }

  /// Switches every connected Device to one Profile.
  func activateProfile(id: UUID) {
    enqueueIntent { [runtime] in
      await runtime.activateProfile(id: id)
    }
  }

  /// Adds one supported Device setup to a Profile.
  func addDeviceConfiguration(
    profileID: UUID,
    descriptor: DeviceModelDescriptor
  ) {
    enqueueIntent { [runtime] in
      await runtime.addDeviceConfiguration(
        profileID: profileID,
        descriptor: descriptor
      )
    }
  }

  /// Removes one Device setup from a Profile.
  func removeDeviceConfiguration(
    profileID: UUID,
    configurationID: UUID
  ) {
    enqueueIntent { [runtime] in
      await runtime.removeDeviceConfiguration(
        profileID: profileID,
        configurationID: configurationID
      )
    }
  }

  /// Runs one configured Binding through the application runtime.
  func testBinding(_ controlID: ControlID) {
    enqueueIntent { [runtime] in
      await runtime.testBinding(controlID)
    }
  }

  /// Sends one demo Control transition.
  func simulate(
    _ controlID: ControlID,
    phase: ControlPhase
  ) {
    enqueueIntent { [runtime] in
      await runtime.simulate(controlID, phase: phase)
    }
  }

  /// Requests Accessibility and refreshes runtime availability.
  func requestAccessibility() {
    enqueueIntent { [runtime] in
      await runtime.requestAccessibility()
    }
  }

  /// Requests Microphone access and refreshes runtime availability.
  func requestMicrophone() {
    enqueueIntent { [runtime] in
      await runtime.requestMicrophone()
    }
  }

  /// Applies one persisted microphone preference to process-owned capture.
  func setPreferredMicrophoneUID(_ uniqueID: String?) {
    enqueueIntent { [runtime] in
      await runtime.setPreferredMicrophoneUID(uniqueID)
    }
  }

  /// Applies one persisted Local AI configuration.
  func setLocalAISettings(_ settings: LocalAISettings) {
    enqueueIntent { [runtime] in
      await runtime.setLocalAISettings(settings)
    }
  }

  /// Refreshes local provider and installed-model readiness.
  func refreshLocalAIReadiness() {
    enqueueIntent { [runtime] in
      await runtime.refreshLocalAIReadiness()
    }
  }

  /// Runs a sanitized generation test through the selected local provider.
  func testLocalAIProvider() {
    guard isStarted, providerTestTask == nil else {
      return
    }
    let applicationStartTask = startTask
    providerTestTask = Task { @MainActor [weak self, runtime] in
      await applicationStartTask?.value
      guard !Task.isCancelled, self?.isStarted == true else {
        self?.providerTestTask = nil
        return
      }
      await runtime.testLocalAIProvider()
      self?.providerTestTask = nil
    }
  }

  /// Requests Speech Recognition and refreshes runtime availability.
  func requestSpeechRecognition() {
    enqueueIntent { [runtime] in
      await runtime.requestSpeechRecognition()
    }
  }

  /// Opens the Microphone privacy settings pane.
  func openMicrophoneSettings() {
    MicrophonePermission.openSystemSettings()
  }

  /// Opens the Speech Recognition privacy settings pane.
  func openSpeechRecognitionSettings() {
    LegacySpeechPermission.openSystemSettings()
  }

  /// Opens the Accessibility privacy settings pane.
  func openAccessibilitySettings() {
    AccessibilityPermission.openSystemSettings()
  }

  /// Copies retained recovery text only after explicit user action.
  func copyRecoverableTranscript() {
    guard transcriptionSnapshot.hasRecoverableTranscript else {
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(
      transcriptionSnapshot.finalText,
      forType: .string
    )
  }

  /// Copies the retained raw or refined AI result after explicit user action.
  func copyLocalAITranscript(refined: Bool) {
    let snapshot = localAIDictationSnapshot
    let text = refined ? snapshot.refinedText : snapshot.rawText
    guard !text.isEmpty else {
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  /// Reveals the current app bundle in Finder.
  func revealInstaller() {
    NSWorkspace.shared.activateFileViewerSelecting(
      [Bundle.main.bundleURL]
    )
  }

  /// Requests a login-item registration change.
  func setLaunchAtLogin(_ enabled: Bool) {
    enqueueIntent { [runtime] in
      await runtime.setLaunchAtLogin(enabled)
    }
  }

  /// Clears current presentation notices.
  func clearNotice() {
    enqueueIntent { [runtime] in
      await runtime.clearNotice()
    }
  }

  /// Preserves main-actor user-intent order before entering the runtime actor.
  private func enqueueIntent(
    _ operation: @escaping @Sendable () async -> Void
  ) {
    guard isStarted else {
      return
    }
    let applicationStartTask = startTask
    let previousTask = intentTask
    intentTask = Task {
      await applicationStartTask?.value
      await previousTask?.value
      guard !Task.isCancelled else {
        return
      }
      await operation()
    }
  }

  /// Maps transcription state into the cursor-adjacent presentation.
  private func refreshTranscriptionIndicator() {
    guard isStarted else {
      return
    }

    let presentation =
      TranscriptionIndicatorPolicy.presentation(
        for: localAIDictationSnapshot
      )
      ?? TranscriptionIndicatorPolicy.presentation(
        for: transcriptionSnapshot
      )
    let caretPoint =
      presentation != nil && accessibilityTrusted
      ? focusedTextTargeter.focusedCaretPoint()
      : nil
    transcriptionIndicator.update(
      presentation,
      anchor: caretPoint
    )
  }
}
