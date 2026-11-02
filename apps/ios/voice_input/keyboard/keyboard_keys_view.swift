import UIKit
import VoiceInputShared

/// Draws the key grid from `VoiceInputKeyboardLayout` rows with the system
/// keyboard's proportions, colors, and press behavior.
@MainActor
final class KeyboardKeysView: UIView {
  /// Fired on touch-down for delete (and its repeats), on touch-up otherwise.
  var onKey: ((VoiceInputKeyboardKey) -> Void)?

  private static let sideMargin: CGFloat = 3
  private static let keyGap: CGFloat = 6
  private static let rowGap: CGFloat = 11
  private static let topMargin: CGFloat = 8
  private static let bottomMargin: CGFloat = 4

  private var rows: [VoiceInputKeyboardRow] = []
  private var keyButtons: [[KeyboardKeyButton]] = []
  private var deleteRepeat: Timer?

  func configure(
    rows: [VoiceInputKeyboardRow],
    isUppercase: Bool,
    isCapsLocked: Bool
  ) {
    if rows != self.rows {
      self.rows = rows
      for button in keyButtons.flatMap({ $0 }) {
        button.removeFromSuperview()
      }
      keyButtons = rows.map { row in
        row.slots.map { slot in
          let button = KeyboardKeyButton(key: slot.key)
          addTarget(for: button)
          addSubview(button)
          return button
        }
      }
      setNeedsLayout()
    }
    for button in keyButtons.flatMap({ $0 }) {
      button.apply(isUppercase: isUppercase, isCapsLocked: isCapsLocked)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard !rows.isEmpty else {
      return
    }
    let rowCount = CGFloat(rows.count)
    let rowHeight =
      (bounds.height - Self.topMargin - Self.bottomMargin - Self.rowGap * (rowCount - 1))
      / rowCount
    let columns = CGFloat(VoiceInputKeyboardLayout.rowWidth)
    let unit =
      (bounds.width - Self.sideMargin * 2 - Self.keyGap * (columns - 1)) / columns
    for (rowIndex, row) in rows.enumerated() {
      let y = Self.topMargin + CGFloat(rowIndex) * (rowHeight + Self.rowGap)
      var x = Self.sideMargin + CGFloat(row.inset) * (unit + Self.keyGap)
      for (slot, button) in zip(row.slots, keyButtons[rowIndex]) {
        // Wider keys absorb the gaps they span, so every row ends flush.
        let width = CGFloat(slot.width) * unit + CGFloat(slot.width - 1) * Self.keyGap
        button.frame = CGRect(x: x, y: y, width: width, height: rowHeight).integral
        x += width + Self.keyGap
      }
    }
  }

  private func addTarget(for button: KeyboardKeyButton) {
    if button.key == .delete {
      button.addTarget(self, action: #selector(beginDelete(_:)), for: .touchDown)
      button.addTarget(
        self,
        action: #selector(endDelete),
        for: [.touchUpInside, .touchUpOutside, .touchCancel]
      )
    } else {
      button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
    }
  }

  @objc private func keyTapped(_ sender: KeyboardKeyButton) {
    UIDevice.current.playInputClick()
    onKey?(sender.key)
  }

  /// Delete fires at once, then repeats after a pause while held.
  @objc private func beginDelete(_ sender: KeyboardKeyButton) {
    UIDevice.current.playInputClick()
    onKey?(.delete)
    deleteRepeat?.invalidate()
    deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) {
          [weak self] _ in
          MainActor.assumeIsolated { self?.onKey?(.delete) }
        }
      }
    }
  }

  @objc private func endDelete() {
    deleteRepeat?.invalidate()
    deleteRepeat = nil
  }
}

/// One key cap. Pressing swaps to the other key color, as the system does.
@MainActor
final class KeyboardKeyButton: UIControl {
  let key: VoiceInputKeyboardKey
  private let label = UILabel()
  private let symbol = UIImageView()
  private var isUppercase = false
  private var isCapsLocked = false

  init(key: VoiceInputKeyboardKey) {
    self.key = key
    super.init(frame: .zero)
    layer.cornerRadius = 8
    layer.cornerCurve = .continuous
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.3
    layer.shadowOffset = CGSize(width: 0, height: 1)
    layer.shadowRadius = 0
    label.textAlignment = .center
    label.adjustsFontForContentSizeCategory = false
    label.isUserInteractionEnabled = false
    symbol.contentMode = .center
    symbol.isUserInteractionEnabled = false
    addSubview(label)
    addSubview(symbol)
    isAccessibilityElement = true
    accessibilityTraits = [.keyboardKey]
    accessibilityIdentifier = Self.identifier(for: key)
    // CGColor borders do not follow appearance changes on their own.
    registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
      (self: Self, _: UITraitCollection) in
      self.refresh()
    }
    refresh()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("Key caps are built in code.")
  }

  override var isHighlighted: Bool {
    didSet { refresh() }
  }

  func apply(isUppercase: Bool, isCapsLocked: Bool) {
    self.isUppercase = isUppercase
    self.isCapsLocked = isCapsLocked
    refresh()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = bounds
    symbol.frame = bounds
    layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 8).cgPath
  }

  private func refresh() {
    let pressedLooksFunction = key.isFunction != isHighlighted
    backgroundColor = pressedLooksFunction ? Self.functionColor : Self.characterColor
    let increasedContrast = traitCollection.accessibilityContrast == .high
    layer.borderWidth = increasedContrast ? 1 : 0
    layer.borderColor = UIColor.label.cgColor
    label.textColor = .label
    symbol.tintColor = .label
    label.text = nil
    symbol.image = nil
    switch key {
    case .character(let character):
      label.text = isUppercase ? character.uppercased() : character
      label.font = .systemFont(ofSize: 24, weight: .regular)
      accessibilityLabel = label.text
    case .space:
      label.text = "space"
      label.font = .systemFont(ofSize: 16)
      accessibilityLabel = "Space"
    case .returnKey:
      label.text = "return"
      label.font = .systemFont(ofSize: 16)
      accessibilityLabel = "Return"
    case .layer(let layer):
      label.text = Self.title(for: layer)
      label.font = .systemFont(ofSize: 16)
      accessibilityLabel = Self.accessibilityTitle(for: layer)
    case .shift:
      let name = isCapsLocked ? "capslock.fill" : (isUppercase ? "shift.fill" : "shift")
      symbol.image = UIImage(systemName: name, withConfiguration: Self.symbolConfiguration)
      accessibilityLabel = isCapsLocked ? "Caps Lock" : "Shift"
      accessibilityValue = isUppercase ? "On" : "Off"
    case .delete:
      symbol.image = UIImage(systemName: "delete.left", withConfiguration: Self.symbolConfiguration)
      accessibilityLabel = "Delete"
    case .nextKeyboard:
      symbol.image = UIImage(systemName: "globe", withConfiguration: Self.symbolConfiguration)
      accessibilityLabel = "Next keyboard"
    }
  }

  private static let symbolConfiguration = UIImage.SymbolConfiguration(
    pointSize: 19,
    weight: .regular
  )

  private static func title(for layer: VoiceInputKeyboardLayer) -> String {
    switch layer {
    case .letters: "ABC"
    case .numbers: "123"
    case .symbols: "#+="
    }
  }

  private static func accessibilityTitle(for layer: VoiceInputKeyboardLayer) -> String {
    switch layer {
    case .letters: "Letters"
    case .numbers: "Numbers"
    case .symbols: "Symbols"
    }
  }

  /// Identifiers stay stable for UI tests and match the earlier keyboard.
  private static func identifier(for key: VoiceInputKeyboardKey) -> String {
    switch key {
    case .character(let character): "key_\(character)"
    case .shift: "shift"
    case .delete: "delete"
    case .layer(let layer): "layer_\(title(for: layer))"
    case .nextKeyboard: "next_keyboard"
    case .space: "space"
    case .returnKey: "return"
    }
  }

  static let characterColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 0.42, alpha: 1)
      : .white
  }

  static let functionColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 0.26, alpha: 1)
      : UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1)
  }
}
