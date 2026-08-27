import UIKit
import VoiceProbeShared

@MainActor
final class KeyboardViewController: UIInputViewController {
  private let policy = VoiceProbeKeyboardPolicy()
  private let store = VoiceProbeKeychainStore()
  private let statusLabel = UILabel()
  private let microphoneButton = UIButton(type: .system)
  private var pollTimer: Timer?
  private var awaitingSessionID: UUID?
  private var isUppercase = false

  override func viewDidLoad() {
    super.viewDidLoad()
    buildKeyboard()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refreshStatus()
    startPolling()
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
    pollTimer?.invalidate()
    pollTimer = nil
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
      statusLabel,
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
    guard let snapshot = try? store.readSnapshot() else {
      showStatus("Shared local state is unavailable.")
      return
    }
    applyDecision(for: snapshot)
  }

  @objc private func pollForResult() {
    guard let awaitingSessionID else {
      return
    }
    guard let snapshot = try? store.readSnapshot() else {
      showStatus("Shared local state is unavailable.")
      self.awaitingSessionID = nil
      return
    }
    guard snapshot.sessionID == awaitingSessionID else {
      showStatus("The active capture session changed. Tap the mic again.")
      self.awaitingSessionID = nil
      return
    }
    if snapshot.phase == .ready {
      applyDecision(for: snapshot)
    } else if snapshot.phase == .interrupted || snapshot.phase == .failed {
      showStatus("Capture stopped without a result. Start again in Voice Probe.")
      self.awaitingSessionID = nil
    }
  }

  private func applyDecision(for snapshot: VoiceProbeSnapshot) {
    let decision = policy.microphoneDecision(
      snapshot: snapshot,
      hasFullAccess: hasFullAccess,
      lastInsertionReceipt: lastInsertionReceipt,
      now: .now
    )
    switch decision {
    case .requiresFullAccess:
      showStatus("Typing works. Enable Full Access for local voice handoff.")
    case .manualActivationRequired:
      showStatus("Start capture in Voice Probe or its Control Center control, then return here.")
    case .requestStop(let sessionID):
      do {
        try store.writeCommand(.stop(sessionID: sessionID, issuedAt: .now))
        awaitingSessionID = sessionID
        showStatus("Stopping local capture…")
      } catch VoiceProbeStoreError.commandPending {
        awaitingSessionID = sessionID
        showStatus("A local capture command is already pending…")
      } catch {
        showStatus("The stop request could not be written locally.")
      }
    case .waitingForResult:
      awaitingSessionID = snapshot.sessionID
      showStatus("Finalizing locally…")
    case .serviceStale:
      showStatus("The app-owned capture is not responding. Start again in Voice Probe.")
    case .insert(let sessionID, let sequence, let text):
      textDocumentProxy.insertText(text)
      lastInsertionReceipt = VoiceProbeInsertionReceipt(
        sessionID: sessionID,
        sequence: sequence
      )
      if awaitingSessionID == sessionID {
        awaitingSessionID = nil
      }
      showStatus("Inserted once.")
    case .alreadyInserted:
      awaitingSessionID = nil
      showStatus("This result was already inserted.")
    }
  }

  private func refreshStatus() {
    microphoneButton.isEnabled = hasFullAccess
    microphoneButton.alpha = hasFullAccess ? 1 : 0.45
    if !hasFullAccess {
      showStatus("Typing works. Full Access enables only the local keychain handoff.")
    } else if statusLabel.text == nil {
      showStatus("Tap the mic after starting capture in Voice Probe or Control Center.")
    }
  }

  private func showStatus(_ text: String) {
    statusLabel.text = text
  }

  private var lastInsertionReceipt: VoiceProbeInsertionReceipt? {
    get {
      guard
        let sessionIDValue = UserDefaults.standard.string(
          forKey: VoiceProbeEnvironment.lastInsertedSessionIDKey
        ),
        let sessionID = UUID(uuidString: sessionIDValue),
        let sequence =
          (UserDefaults.standard.object(
            forKey: VoiceProbeEnvironment.lastInsertedSequenceKey
          ) as? NSNumber)?.uint64Value
      else {
        return nil
      }
      return VoiceProbeInsertionReceipt(sessionID: sessionID, sequence: sequence)
    }
    set {
      if let newValue {
        UserDefaults.standard.set(
          newValue.sessionID.uuidString,
          forKey: VoiceProbeEnvironment.lastInsertedSessionIDKey
        )
        UserDefaults.standard.set(
          NSNumber(value: newValue.sequence),
          forKey: VoiceProbeEnvironment.lastInsertedSequenceKey
        )
      } else {
        UserDefaults.standard.removeObject(
          forKey: VoiceProbeEnvironment.lastInsertedSessionIDKey
        )
        UserDefaults.standard.removeObject(
          forKey: VoiceProbeEnvironment.lastInsertedSequenceKey
        )
      }
    }
  }
}

extension UIView {
  fileprivate var subviewsRecursive: [UIView] {
    subviews + subviews.flatMap(\.subviewsRecursive)
  }
}
