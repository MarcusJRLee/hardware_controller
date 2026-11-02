/// The Voice Keyboard's keys and typing rules. Pure, so layers, widths, and
/// capitalization are tested without a keyboard host.
public enum VoiceInputKeyboardKey: Equatable, Hashable, Sendable {
  case character(String)
  case shift
  case delete
  case layer(VoiceInputKeyboardLayer)
  case nextKeyboard
  case space
  case returnKey

  /// Characters, space, and the layer toggles read as primary keys; the rest
  /// use the darker function style, as on the system keyboard.
  public var isFunction: Bool {
    switch self {
    case .character, .space: false
    case .shift, .delete, .layer, .nextKeyboard, .returnKey: true
    }
  }
}

public enum VoiceInputKeyboardLayer: Equatable, Hashable, Sendable {
  case letters
  case numbers
  case symbols
}

public struct VoiceInputKeyboardSlot: Equatable, Sendable {
  public let key: VoiceInputKeyboardKey
  /// Width relative to one letter key.
  public let width: Double

  public init(_ key: VoiceInputKeyboardKey, width: Double = 1) {
    self.key = key
    self.width = width
  }
}

public struct VoiceInputKeyboardRow: Equatable, Sendable {
  public let slots: [VoiceInputKeyboardSlot]
  /// Empty space before the first key, in letter-key widths, so the shorter
  /// middle row centers as on the system keyboard.
  public let inset: Double

  public init(_ slots: [VoiceInputKeyboardSlot], inset: Double = 0) {
    self.slots = slots
    self.inset = inset
  }
}

public enum VoiceInputKeyboardLayout {
  /// Ten letter-key widths per row; every row sums to this with its insets.
  public static let rowWidth = 10.0

  public static func rows(
    for layer: VoiceInputKeyboardLayer,
    showsNextKeyboard: Bool
  ) -> [VoiceInputKeyboardRow] {
    let characters: [String]
    let third: [String]
    let toggle: VoiceInputKeyboardSlot
    switch layer {
    case .letters:
      characters = ["qwertyuiop", "asdfghjkl"]
      third = "zxcvbnm".map(String.init)
      toggle = VoiceInputKeyboardSlot(.shift, width: 1.5)
    case .numbers:
      characters = ["1234567890", "-/:;()$&@\""]
      third = [".", ",", "?", "!", "'"]
      toggle = VoiceInputKeyboardSlot(.layer(.symbols), width: 1.5)
    case .symbols:
      characters = ["[]{}#%^*+=", "_\\|~<>€£¥•"]
      third = [".", ",", "?", "!", "'"]
      toggle = VoiceInputKeyboardSlot(.layer(.numbers), width: 1.5)
    }
    let top = characters.map { row in row.map { VoiceInputKeyboardSlot(.character(String($0))) } }
    let thirdKeyWidth = (rowWidth - 3) / Double(third.count)
    return [
      VoiceInputKeyboardRow(top[0]),
      VoiceInputKeyboardRow(top[1], inset: (rowWidth - Double(top[1].count)) / 2),
      VoiceInputKeyboardRow(
        [toggle]
          + third.map { VoiceInputKeyboardSlot(.character($0), width: thirdKeyWidth) }
          + [VoiceInputKeyboardSlot(.delete, width: 1.5)]
      ),
      bottomRow(layer: layer, showsNextKeyboard: showsNextKeyboard),
    ]
  }

  private static func bottomRow(
    layer: VoiceInputKeyboardLayer,
    showsNextKeyboard: Bool
  ) -> VoiceInputKeyboardRow {
    let layerToggle = VoiceInputKeyboardSlot(
      .layer(layer == .letters ? .numbers : .letters),
      width: 1.25
    )
    let returnKey = VoiceInputKeyboardSlot(.returnKey, width: 2)
    let fixed = showsNextKeyboard ? 1.25 + 1.25 + 2 : 1.25 + 2
    let space = VoiceInputKeyboardSlot(.space, width: rowWidth - fixed)
    let leading =
      showsNextKeyboard
      ? [layerToggle, VoiceInputKeyboardSlot(.nextKeyboard, width: 1.25)]
      : [layerToggle]
    return VoiceInputKeyboardRow(leading + [space, returnKey])
  }

  /// Sentence-start capitalization from the text before the cursor.
  public static func shouldCapitalize(after context: String?) -> Bool {
    guard let context, let last = context.last(where: { $0 != " " }) else {
      return true
    }
    if last.isNewline {
      return true
    }
    // A sentence end counts only once a space follows it.
    return context.last == " " && ".!?".contains(last)
  }

  /// Double space after a word becomes ". ", as on the system keyboard.
  public static func shouldInsertPeriod(after context: String?) -> Bool {
    guard
      let context,
      context.last == " ",
      let previous = context.dropLast().last
    else {
      return false
    }
    return previous.isLetter || previous.isNumber
  }
}
