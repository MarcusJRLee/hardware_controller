import UIKit
import VoiceInputShared

@MainActor
final class KeyboardViewController: UIInputViewController {
  private let policy = VoiceInputKeyboardPolicy()
  private let hostFieldPolicy = VoiceInputHostFieldPolicy()
  private let fieldMapper = VoiceInputUIKitFieldMapper()
  private let deliveryTargetPolicy = VoiceInputDeliveryTargetPolicy()
  private let insertionRecoveryPolicy = VoiceInputInsertionRecoveryPolicy()
  private let localClipboard = VoiceInputSystemLocalClipboard()
  private let store = VoiceInputKeychainStore()
  private let stylePreference = VoiceInputStylePreferenceStore(
    key: VoiceInputEnvironment.keyboardStyleKindKey
  )
  private let statusLabel = UILabel()
  private let insertionRecoveryButton = UIButton(type: .system)
  private let restartButton = UIButton(type: .system)
  private let styleButton = UIButton(type: .system)
  private let microphoneButton = UIButton(type: .system)
  private var pollTimer: Timer?
  private var insertionConfirmationTask: Task<Void, Never>?
  private var deliveryTarget: VoiceInputDeliveryTarget?
  private var insertionRecovery: VoiceInputInsertionRecovery?
  private var hostChangeRevision: UInt64 = 0
  private var selectedStyleKind = VoiceInputStyleKind.natural
  private let keysView = KeyboardKeysView()
  private var layer = VoiceInputKeyboardLayer.letters
  private var isUppercase = false
  private var isCapsLocked = false
  private var lastShiftTap: Date?
  private var indicatorTimer: Timer?
  private var indicatedPhase: VoiceInputSnapshot.Phase?

  override func viewDidLoad() {
    super.viewDidLoad()
    inputView = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
    selectedStyleKind = stylePreference.read()
    buildKeyboard()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    updateAutoCapitalization()
    renderKeys()
    refreshStatus()
    startIndicator()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    // The globe key depends on the host, which is known only once presented.
    renderKeys()
  }

  private func startPolling() {
    guard pollTimer == nil else {
      return
    }
    pollTimer = Timer.scheduledTimer(
      timeInterval: 0.25,
      target: self,
      selector: #selector(pollForResult),
      userInfo: nil,
      repeats: true
    )
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    stopPolling()
    indicatorTimer?.invalidate()
    indicatorTimer = nil
    clearInsertionRecovery()
  }

  private func stopPolling() {
    pollTimer?.invalidate()
    pollTimer = nil
  }

  override func textDidChange(_ textInput: (any UITextInput)?) {
    let insertionWasPending = insertionRecovery != nil
    hostChangeRevision &+= 1
    super.textDidChange(textInput)
    updateAutoCapitalization()
    renderKeys()
    refreshStatus()
    if insertionWasPending {
      clearInsertionRecovery()
      showStatus("Field update confirmed.")
    }
  }

  override func selectionDidChange(_ textInput: (any UITextInput)?) {
    let insertionWasPending = insertionRecovery != nil
    hostChangeRevision &+= 1
    super.selectionDidChange(textInput)
    refreshStatus()
    if insertionWasPending {
      clearInsertionRecovery()
      showStatus("The field changed. The text is in Voice Input History.")
    }
  }

  private func buildKeyboard() {
    statusLabel.font = .preferredFont(forTextStyle: .caption1)
    statusLabel.adjustsFontForContentSizeCategory = false
    statusLabel.textColor = .secondaryLabel
    statusLabel.numberOfLines = 2
    statusLabel.textAlignment = .center
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.accessibilityIdentifier = "voice_status"

    keysView.onKey = { [weak self] key in self?.handle(key) }
    let bar = voiceBar
    bar.translatesAutoresizingMaskIntoConstraints = false
    keysView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(bar)
    view.addSubview(keysView)
    // The system may resize the keyboard; one height keeps keys stable.
    let height = view.heightAnchor.constraint(equalToConstant: 270)
    height.priority = .defaultHigh
    NSLayoutConstraint.activate([
      height,
      bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
      bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
      bar.heightAnchor.constraint(equalToConstant: 44),
      keysView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      keysView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      keysView.topAnchor.constraint(equalTo: bar.bottomAnchor),
      keysView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    configureMicrophoneButton()
    renderKeys()
  }

  /// Style on the left, status in the middle, the voice button on the right.
  private var voiceBar: UIStackView {
    insertionRecoveryButton.configuration = Self.barButtonConfiguration(title: "Recover…")
    insertionRecoveryButton.accessibilityLabel = "Recover unconfirmed voice insertion"
    insertionRecoveryButton.accessibilityIdentifier = "voice_insertion_recovery"
    insertionRecoveryButton.showsMenuAsPrimaryAction = true
    insertionRecoveryButton.isHidden = true
    insertionRecoveryButton.setContentHuggingPriority(.required, for: .horizontal)

    restartButton.configuration = Self.barButtonConfiguration(title: "Restart…")
    restartButton.accessibilityLabel = "Show voice restart steps"
    restartButton.accessibilityIdentifier = "voice_restart"
    restartButton.isHidden = true
    restartButton.addTarget(self, action: #selector(showRestartSteps), for: .touchUpInside)
    restartButton.setContentHuggingPriority(.required, for: .horizontal)

    styleButton.accessibilityLabel = "Dictation style"
    styleButton.accessibilityIdentifier = "voice_style"
    styleButton.showsMenuAsPrimaryAction = true
    styleButton.setContentHuggingPriority(.required, for: .horizontal)
    styleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    configureStyleMenu()

    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [
      styleButton,
      statusLabel,
      insertionRecoveryButton,
      restartButton,
      microphoneButton,
    ])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 8
    return row
  }

  private static func barButtonConfiguration(title: String) -> UIButton.Configuration {
    var configuration = UIButton.Configuration.plain()
    configuration.title = title
    configuration.baseForegroundColor = .label
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 4, leading: 6, bottom: 4, trailing: 6)
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      var attributes = $0
      attributes.font = .preferredFont(forTextStyle: .subheadline)
      return attributes
    }
    return configuration
  }

  private func configureMicrophoneButton() {
    microphoneButton.accessibilityLabel = "Voice capture"
    microphoneButton.accessibilityIdentifier = "voice_microphone"
    microphoneButton.layer.cornerRadius = 20
    microphoneButton.layer.cornerCurve = .continuous
    microphoneButton.addTarget(self, action: #selector(handleMicrophone), for: .touchUpInside)
    microphoneButton.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      microphoneButton.widthAnchor.constraint(equalToConstant: 40),
      microphoneButton.heightAnchor.constraint(equalToConstant: 40),
    ])
    showCapturePhase(nil)
  }

  /// Neutral at rest; amber only while the app records, as in the app.
  private func showCapturePhase(_ phase: VoiceInputSnapshot.Phase?) {
    let symbol: String
    switch phase {
    case .recording:
      microphoneButton.backgroundColor = VoiceInputTheme.signal
      microphoneButton.tintColor = .black
      symbol = "stop.fill"
      microphoneButton.accessibilityValue = "Recording"
    case .transcribing:
      microphoneButton.backgroundColor = .secondarySystemFill
      microphoneButton.tintColor = .label
      symbol = "ellipsis"
      microphoneButton.accessibilityValue = "Finishing"
    case .none, .idle, .ready, .interrupted, .failed:
      microphoneButton.backgroundColor = .label
      microphoneButton.tintColor = .systemBackground
      symbol = "mic.fill"
      microphoneButton.accessibilityValue = nil
    }
    microphoneButton.setImage(
      UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
      ),
      for: .normal
    )
  }

  private func startIndicator() {
    guard indicatorTimer == nil else {
      return
    }
    updateIndicator()
    indicatorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateIndicator() }
    }
  }

  /// Reads only the bounded snapshot; it never starts or stops capture.
  private func updateIndicator() {
    let phase = hasFullAccess ? (try? store.readSnapshot())?.phase : nil
    guard phase != indicatedPhase else {
      return
    }
    indicatedPhase = phase
    showCapturePhase(phase)
  }

  private func renderKeys() {
    keysView.configure(
      rows: VoiceInputKeyboardLayout.rows(for: layer, showsNextKeyboard: needsInputModeSwitchKey),
      isUppercase: layer == .letters && (isUppercase || isCapsLocked),
      isCapsLocked: isCapsLocked
    )
  }

  private func handle(_ key: VoiceInputKeyboardKey) {
    switch key {
    case .character(let character):
      let uppercase = layer == .letters && (isUppercase || isCapsLocked)
      textDocumentProxy.insertText(uppercase ? character.uppercased() : character)
      if !isCapsLocked {
        isUppercase = false
      }
      if layer != .letters, character == "'" {
        layer = .letters
      }
    case .space:
      if VoiceInputKeyboardLayout.shouldInsertPeriod(
        after: textDocumentProxy.documentContextBeforeInput)
      {
        textDocumentProxy.deleteBackward()
        textDocumentProxy.insertText(". ")
      } else {
        textDocumentProxy.insertText(" ")
      }
      layer = .letters
      updateAutoCapitalization()
    case .returnKey:
      textDocumentProxy.insertText("\n")
      layer = .letters
      updateAutoCapitalization()
    case .delete:
      textDocumentProxy.deleteBackward()
      updateAutoCapitalization()
    case .shift:
      toggleShift()
    case .layer(let next):
      layer = next
    case .nextKeyboard:
      advanceToNextInputMode()
    }
    renderKeys()
  }

  /// One tap shifts the next letter; a quick second tap locks capitals.
  private func toggleShift() {
    let now = Date.now
    if isCapsLocked {
      isCapsLocked = false
      isUppercase = false
    } else if isUppercase, let lastShiftTap, now.timeIntervalSince(lastShiftTap) < 0.35 {
      isCapsLocked = true
    } else {
      isUppercase.toggle()
    }
    lastShiftTap = now
  }

  private func updateAutoCapitalization() {
    guard !isCapsLocked else {
      return
    }
    let autocapitalizes = (textDocumentProxy.autocapitalizationType ?? .sentences) != .none
    isUppercase =
      autocapitalizes
      && VoiceInputKeyboardLayout.shouldCapitalize(
        after: textDocumentProxy.documentContextBeforeInput)
  }

  @objc private func handleMicrophone() {
    clearInsertionRecovery()
    guard hasFullAccess else {
      restartButton.isHidden = true
      showStatus("To dictate here, turn on Allow Full Access for Voice Keyboard.")
      return
    }
    guard currentFieldEligibility == .supported else {
      deliveryTarget = nil
      restartButton.isHidden = true
      showStatus("Voice is off in this field. Typing still works.")
      return
    }
    guard let snapshot = try? store.readSnapshot() else {
      showStaleService("Shared local state is unavailable.")
      return
    }
    applyDecision(for: snapshot)
  }

  @objc private func pollForResult() {
    guard let deliveryTarget else {
      stopPolling()
      return
    }
    guard !invalidateDeliveryTargetIfNeeded() else {
      stopPolling()
      showStatus("The field changed. The text is in Voice Input History.")
      return
    }
    guard let snapshot = try? store.readSnapshot() else {
      showStaleService("Shared local state is unavailable.")
      return
    }
    guard snapshot.sessionID == deliveryTarget.sessionID else {
      showStatus(
        "The capture session changed. Recover the earlier result from Voice Input History.")
      self.deliveryTarget = nil
      stopPolling()
      return
    }
    let insertionReceipt: VoiceInputInsertionReceipt?
    do {
      insertionReceipt = try store.readInsertionReceipt()
    } catch {
      showStaleService("The local insertion receipt is unavailable.")
      return
    }
    let decision = policy.microphoneDecision(
      snapshot: snapshot,
      hasFullAccess: hasFullAccess,
      fieldEligibility: currentFieldEligibility,
      lastInsertionReceipt: insertionReceipt,
      now: .now
    )
    switch decision {
    case .requestStop:
      showStatus("Stopping…")
    case .waitingForResult:
      showStatus("Transcribing…")
    case .serviceStale:
      showStaleService("The app-owned capture stopped responding.")
    case .insert, .alreadyInserted:
      applyDecision(for: snapshot)
    case .manualActivationRequired:
      showStatus("Recording stopped without text. Start again in Voice Input.")
      self.deliveryTarget = nil
      stopPolling()
    case .requiresFullAccess, .unsupportedField:
      applyDecision(for: snapshot)
    }
  }

  private func applyDecision(for snapshot: VoiceInputSnapshot) {
    clearInsertionRecovery()
    restartButton.isHidden = true
    let insertionReceipt: VoiceInputInsertionReceipt?
    do {
      insertionReceipt = try store.readInsertionReceipt()
    } catch {
      showStaleService("The local insertion receipt is unavailable.")
      return
    }
    let decision = policy.microphoneDecision(
      snapshot: snapshot,
      hasFullAccess: hasFullAccess,
      fieldEligibility: currentFieldEligibility,
      lastInsertionReceipt: insertionReceipt,
      now: .now
    )
    switch decision {
    case .requiresFullAccess:
      deliveryTarget = nil
      stopPolling()
      showStatus("To dictate here, turn on Allow Full Access for Voice Keyboard.")
    case .unsupportedField:
      deliveryTarget = nil
      stopPolling()
      showStatus("Voice is off in this field. Typing still works.")
    case .manualActivationRequired:
      deliveryTarget = nil
      showStatus("Start recording in Voice Input or Control Center, then tap the mic.")
    case .requestStop(let sessionID):
      let requestedTarget = VoiceInputDeliveryTarget(
        sessionID: sessionID,
        documentIdentifier: textDocumentProxy.documentIdentifier,
        hostChangeRevision: hostChangeRevision,
        stopRequestedAfterSequence: snapshot.sequence
      )
      do {
        try store.writeCommand(
          .stop(
            sessionID: sessionID,
            styleKind: selectedStyleKind,
            issuedAt: .now
          )
        )
        deliveryTarget = requestedTarget
        restartButton.isHidden = true
        startPolling()
        showStatus("Stopping…")
      } catch VoiceInputStoreError.commandPending {
        if deliveryTarget == requestedTarget {
          showStatus("A local capture command is already pending…")
        } else {
          deliveryTarget = nil
          showStatus("Another stop is pending. Recover its result from Voice Input History.")
        }
      } catch {
        deliveryTarget = nil
        showStatus("The stop request could not be written locally.")
      }
    case .waitingForResult:
      showStatus("Transcribing…")
    case .serviceStale:
      showStaleService("The app-owned capture is not responding.")
    case .insert(let sessionID, let sequence, let text):
      guard
        let deliveryTarget,
        deliveryTargetPolicy.decision(
          sessionID: sessionID,
          resultSequence: sequence,
          documentIdentifier: textDocumentProxy.documentIdentifier,
          hostChangeRevision: hostChangeRevision,
          target: deliveryTarget
        ) == .deliver
      else {
        self.deliveryTarget = nil
        stopPolling()
        showStatus("The field changed. The text is in Voice Input History.")
        return
      }
      let receipt = VoiceInputInsertionReceipt(
        sessionID: sessionID,
        sequence: sequence
      )
      do {
        guard try store.claimInsertion(receipt) else {
          self.deliveryTarget = nil
          stopPolling()
          showStatus("This result was already inserted.")
          return
        }
      } catch {
        showStatus("The local insertion receipt could not be saved.")
        return
      }
      // The durable claim precedes the first side effect; one explicit retry remains process-local.
      self.deliveryTarget = nil
      stopPolling()
      beginInsertionAttempt(
        VoiceInputInsertionRecovery(
          sessionID: sessionID,
          resultSequence: sequence,
          text: text,
          target: deliveryTarget
        )
      )
    case .alreadyInserted:
      deliveryTarget = nil
      stopPolling()
      showStatus("This result was already inserted.")
    }
  }

  private func refreshStatus() {
    let deliveryTargetWasInvalidated = invalidateDeliveryTargetIfNeeded()
    let insertionRecoveryWasInvalidated = invalidateInsertionRecoveryIfNeeded()
    let fullAccess = hasFullAccess
    let fieldEligibility = currentFieldEligibility
    let voiceAvailable = fullAccess && fieldEligibility == .supported
    microphoneButton.isEnabled = voiceAvailable
    microphoneButton.alpha = voiceAvailable ? 1 : 0.45
    if fullAccess {
      do {
        try store.markKeyboardObserved(at: .now)
      } catch {
        showStatus("The local handoff could not be confirmed.")
        return
      }
    }
    if !fullAccess {
      restartButton.isHidden = true
      showStatus("To dictate here, turn on Allow Full Access for Voice Keyboard.")
    } else if fieldEligibility == .unsupported {
      restartButton.isHidden = true
      showStatus("Voice is off in this field. Typing still works.")
    } else if deliveryTargetWasInvalidated {
      restartButton.isHidden = true
      showStatus("The field changed. The text is in Voice Input History.")
    } else if insertionRecoveryWasInvalidated {
      showStatus("The field changed. The text is in Voice Input History.")
    } else if statusLabel.text == nil {
      showStatus("Start recording in Voice Input, then tap the mic to insert.")
    }
  }

  private var currentFieldEligibility: VoiceInputFieldEligibility {
    hostFieldPolicy.eligibility(
      for: fieldMapper.kind(
        keyboardType: textDocumentProxy.keyboardType,
        textContentType: textDocumentProxy.textContentType
      )
    )
  }

  private func invalidateDeliveryTargetIfNeeded() -> Bool {
    guard let deliveryTarget else {
      return false
    }
    guard
      currentFieldEligibility == .supported,
      deliveryTarget.documentIdentifier == textDocumentProxy.documentIdentifier,
      deliveryTarget.hostChangeRevision == hostChangeRevision
    else {
      self.deliveryTarget = nil
      return true
    }
    return false
  }

  private func invalidateInsertionRecoveryIfNeeded() -> Bool {
    guard let insertionRecovery else {
      return false
    }
    guard
      currentFieldEligibility == .supported,
      insertionRecovery.target.documentIdentifier == textDocumentProxy.documentIdentifier,
      insertionRecovery.target.hostChangeRevision == hostChangeRevision
    else {
      clearInsertionRecovery()
      return true
    }
    return false
  }

  private func showStatus(_ text: String) {
    statusLabel.text = text
  }

  private func showStaleService(_ text: String) {
    clearInsertionRecovery()
    deliveryTarget = nil
    stopPolling()
    restartButton.isHidden = false
    showStatus(text)
  }

  @objc private func showRestartSteps() {
    restartButton.isHidden = true
    showStatus(
      "Open Voice Input or use its Control Center control to start again, then return here.")
  }

  private func beginInsertionAttempt(_ recovery: VoiceInputInsertionRecovery) {
    insertionRecovery = recovery
    insertionRecoveryButton.isHidden = true
    insertionConfirmationTask?.cancel()
    showStatus(recovery.retryCount == 0 ? "Confirming insertion…" : "Confirming retry…")
    insertionConfirmationTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else {
        return
      }
      self?.offerInsertionRecovery(for: recovery)
    }
    textDocumentProxy.insertText(recovery.text)
  }

  private func offerInsertionRecovery(for expected: VoiceInputInsertionRecovery) {
    guard insertionRecovery == expected else {
      return
    }
    configureInsertionRecoveryMenu(expected)
    insertionRecoveryButton.isHidden = false
    showStatus(
      expected.retryCount == 0
        ? "No field update was confirmed. Retry once or copy locally."
        : "No field update was confirmed. Copy locally or recover from History."
    )
  }

  private func configureInsertionRecoveryMenu(_ recovery: VoiceInputInsertionRecovery) {
    var actions: [UIAction] = []
    if recovery.retryCount < insertionRecoveryPolicy.maximumRetryCount {
      actions.append(
        UIAction(title: "Retry insertion once", image: UIImage(systemName: "arrow.clockwise")) {
          [weak self] _ in
          self?.retryInsertion()
        }
      )
    }
    actions.append(
      UIAction(
        title: "Copy on this device for 10 minutes",
        image: UIImage(systemName: "doc.on.doc")
      ) {
        [weak self] _ in
        self?.copyInsertionLocally()
      }
    )
    insertionRecoveryButton.menu = UIMenu(title: "Recover insertion", children: actions)
  }

  private func retryInsertion() {
    guard
      let recovery = validatedInsertionRecovery(for: .retry),
      recovery.retryCount < insertionRecoveryPolicy.maximumRetryCount
    else {
      return
    }
    beginInsertionAttempt(recovery.recordingRetry())
  }

  private func copyInsertionLocally() {
    guard let recovery = validatedInsertionRecovery(for: .copy) else {
      return
    }
    do {
      try localClipboard.copy(recovery.text)
      clearInsertionRecovery()
      showStatus("Copied on this device. The clipboard entry expires in 10 minutes.")
    } catch {
      recoverInsertionFromHistory("The transcript is too large to copy safely.")
    }
  }

  private func validatedInsertionRecovery(
    for action: VoiceInputInsertionRecoveryAction
  ) -> VoiceInputInsertionRecovery? {
    guard
      hasFullAccess,
      currentFieldEligibility == .supported,
      let recovery = insertionRecovery,
      let snapshot = try? store.readSnapshot(),
      let receipt = try? store.readInsertionReceipt()
    else {
      recoverInsertionFromHistory("Insertion recovery is no longer available.")
      return nil
    }
    switch insertionRecoveryPolicy.decision(
      for: action,
      recovery: recovery,
      snapshot: snapshot,
      receipt: receipt,
      documentIdentifier: textDocumentProxy.documentIdentifier,
      hostChangeRevision: hostChangeRevision
    ) {
    case .perform:
      return recovery
    case .retryLimitReached:
      offerInsertionRecovery(for: recovery)
    case .recoverFromHistory:
      recoverInsertionFromHistory(
        "The target changed. Recover the transcript from Voice Input History.")
    }
    return nil
  }

  private func recoverInsertionFromHistory(_ message: String) {
    clearInsertionRecovery()
    showStatus(message)
  }

  private func clearInsertionRecovery() {
    insertionConfirmationTask?.cancel()
    insertionConfirmationTask = nil
    insertionRecovery = nil
    insertionRecoveryButton.isHidden = true
    insertionRecoveryButton.menu = nil
  }

  private func configureStyleMenu() {
    var configuration = UIButton.Configuration.gray()
    configuration.title = selectedStyleKind.displayName
    configuration.image = UIImage(
      systemName: "chevron.down",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
    )
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 4
    configuration.cornerStyle = .capsule
    configuration.baseForegroundColor = .label
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 6, leading: 12, bottom: 6, trailing: 10)
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      var attributes = $0
      attributes.font = .preferredFont(forTextStyle: .subheadline)
      return attributes
    }
    styleButton.configuration = configuration
    styleButton.menu = UIMenu(
      title: "Style",
      children: VoiceInputStyleKind.allCases.map { styleKind in
        UIAction(
          title: styleKind.displayName,
          state: styleKind == selectedStyleKind ? .on : .off
        ) { [weak self] _ in
          self?.selectStyle(styleKind)
        }
      }
    )
  }

  private func selectStyle(_ styleKind: VoiceInputStyleKind) {
    selectedStyleKind = styleKind
    stylePreference.write(styleKind)
    configureStyleMenu()
    showStatus("\(styleKind.displayName) Style selected for the next result.")
  }

}

/// Enables the system's input clicks for this keyboard's keys.
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
  var enableInputClicksWhenVisible: Bool { true }
}
