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
  private var isUppercase = false

  override func viewDidLoad() {
    super.viewDidLoad()
    selectedStyleKind = stylePreference.read()
    buildKeyboard()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refreshStatus()
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
      showStatus("The field changed. The transcript remains in Voice Input History.")
    }
  }

  private func buildKeyboard() {
    view.backgroundColor = .systemGray6
    view.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true

    statusLabel.font = .preferredFont(forTextStyle: .caption1)
    statusLabel.textColor = .secondaryLabel
    statusLabel.numberOfLines = 2
    statusLabel.textAlignment = .center
    statusLabel.accessibilityIdentifier = "voice_status"

    let rows = UIStackView(arrangedSubviews: [
      statusAndStyleRow,
      letterRow("qwertyuiop"),
      letterRow("asdfghjkl"),
      thirdRow,
      utilityRow,
    ])
    rows.axis = .vertical
    rows.spacing = 7
    rows.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(rows)
    NSLayoutConstraint.activate([
      rows.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
      rows.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
      rows.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
      rows.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
    ])
  }

  private var statusAndStyleRow: UIStackView {
    insertionRecoveryButton.setTitle("Recover…", for: .normal)
    insertionRecoveryButton.accessibilityLabel = "Recover unconfirmed voice insertion"
    insertionRecoveryButton.accessibilityIdentifier = "voice_insertion_recovery"
    insertionRecoveryButton.showsMenuAsPrimaryAction = true
    insertionRecoveryButton.isHidden = true
    insertionRecoveryButton.setContentHuggingPriority(.required, for: .horizontal)

    restartButton.setTitle("Restart…", for: .normal)
    restartButton.accessibilityLabel = "Show voice restart steps"
    restartButton.accessibilityIdentifier = "voice_restart"
    restartButton.isHidden = true
    restartButton.addTarget(self, action: #selector(showRestartSteps), for: .touchUpInside)
    restartButton.setContentHuggingPriority(.required, for: .horizontal)

    styleButton.accessibilityLabel = "Dictation style"
    styleButton.accessibilityIdentifier = "voice_style"
    styleButton.showsMenuAsPrimaryAction = true
    styleButton.setContentHuggingPriority(.required, for: .horizontal)
    configureStyleMenu()

    let row = UIStackView(arrangedSubviews: [
      statusLabel,
      insertionRecoveryButton,
      restartButton,
      styleButton,
    ])
    row.axis = .horizontal
    row.spacing = 8
    return row
  }

  private func letterRow(_ letters: String) -> UIStackView {
    stack(letters.map { letterButton(String($0)) })
  }

  private var thirdRow: UIStackView {
    let shift = keyButton(title: "⇧", identifier: "shift")
    shift.addTarget(self, action: #selector(toggleCase), for: .touchUpInside)
    let delete = keyButton(title: "⌫", identifier: "delete")
    delete.addTarget(self, action: #selector(deleteBackward), for: .touchUpInside)
    return stack([shift] + "zxcvbnm".map { letterButton(String($0)) } + [delete])
  }

  private var utilityRow: UIStackView {
    let globe = keyButton(title: "◉", identifier: "next_keyboard")
    globe.addTarget(self, action: #selector(nextKeyboard), for: .touchUpInside)

    microphoneButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
    microphoneButton.accessibilityLabel = "Voice capture"
    microphoneButton.accessibilityIdentifier = "voice_microphone"
    microphoneButton.backgroundColor = .label
    microphoneButton.tintColor = .systemBackground
    microphoneButton.layer.cornerRadius = 8
    microphoneButton.addTarget(self, action: #selector(handleMicrophone), for: .touchUpInside)

    let space = keyButton(title: "space", identifier: "space")
    space.addTarget(self, action: #selector(insertSpace), for: .touchUpInside)
    space.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

    let returnKey = keyButton(title: "return", identifier: "return")
    returnKey.addTarget(self, action: #selector(insertReturn), for: .touchUpInside)
    return stack([globe, microphoneButton, space, returnKey])
  }

  private func stack(_ views: [UIView]) -> UIStackView {
    let row = UIStackView(arrangedSubviews: views)
    row.axis = .horizontal
    row.spacing = 5
    row.distribution = .fillEqually
    return row
  }

  private func letterButton(_ letter: String) -> UIButton {
    let button = keyButton(
      title: isUppercase ? letter.uppercased() : letter,
      identifier: "key_\(letter)"
    )
    button.addTarget(self, action: #selector(insertLetter(_:)), for: .touchUpInside)
    return button
  }

  private func keyButton(title: String, identifier: String) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.setTitleColor(.label, for: .normal)
    button.titleLabel?.font = .preferredFont(forTextStyle: .body)
    button.backgroundColor = .systemBackground
    button.layer.cornerRadius = 6
    button.accessibilityIdentifier = identifier
    return button
  }

  @objc private func insertLetter(_ sender: UIButton) {
    guard let letter = sender.title(for: .normal) else {
      return
    }
    textDocumentProxy.insertText(letter)
    if isUppercase {
      toggleCase()
    }
  }

  @objc private func insertSpace() {
    textDocumentProxy.insertText(" ")
  }

  @objc private func insertReturn() {
    textDocumentProxy.insertText("\n")
  }

  @objc private func deleteBackward() {
    textDocumentProxy.deleteBackward()
  }

  @objc private func nextKeyboard() {
    advanceToNextInputMode()
  }

  @objc private func toggleCase() {
    isUppercase.toggle()
    for case let button as UIButton in view.subviewsRecursive {
      guard
        let identifier = button.accessibilityIdentifier,
        identifier.hasPrefix("key_")
      else {
        continue
      }
      let letter = String(identifier.dropFirst(4))
      button.setTitle(isUppercase ? letter.uppercased() : letter, for: .normal)
    }
  }

  @objc private func handleMicrophone() {
    clearInsertionRecovery()
    guard hasFullAccess else {
      restartButton.isHidden = true
      showStatus("Typing works. Enable Full Access for local voice handoff.")
      return
    }
    guard currentFieldEligibility == .supported else {
      deliveryTarget = nil
      restartButton.isHidden = true
      showStatus("Typing works. Voice capture is unavailable in this field.")
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
      showStatus("The field changed. Recover the completed transcript from Voice Input History.")
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
      showStatus("Stopping local capture…")
    case .waitingForResult:
      showStatus("Finalizing locally…")
    case .serviceStale:
      showStaleService("The app-owned capture stopped responding.")
    case .insert, .alreadyInserted:
      applyDecision(for: snapshot)
    case .manualActivationRequired:
      showStatus("Capture stopped without a result. Start again in Voice Input.")
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
      showStatus("Typing works. Enable Full Access for local voice handoff.")
    case .unsupportedField:
      deliveryTarget = nil
      stopPolling()
      showStatus("Typing works. Voice capture is unavailable in this field.")
    case .manualActivationRequired:
      deliveryTarget = nil
      showStatus("Start capture in Voice Input or its Control Center control, then return here.")
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
        showStatus("Stopping local capture…")
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
      showStatus("Finalizing locally…")
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
        showStatus("The field changed. Recover the completed transcript from Voice Input History.")
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
      showStatus("Typing works. Full Access enables only the local keychain handoff.")
    } else if fieldEligibility == .unsupported {
      restartButton.isHidden = true
      showStatus("Typing works. Voice capture is unavailable in this field.")
    } else if deliveryTargetWasInvalidated {
      restartButton.isHidden = true
      showStatus("The field changed. Recover the completed transcript from Voice Input History.")
    } else if insertionRecoveryWasInvalidated {
      showStatus("The field changed. The transcript remains in Voice Input History.")
    } else if statusLabel.text == nil {
      showStatus("Tap the mic after starting capture in Voice Input or Control Center.")
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
    styleButton.setTitle(selectedStyleKind.displayName, for: .normal)
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

extension UIView {
  fileprivate var subviewsRecursive: [UIView] {
    subviews + subviews.flatMap(\.subviewsRecursive)
  }
}
