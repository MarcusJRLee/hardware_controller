import Foundation

/// Applies Dictionary replacements to recognized text.
///
/// Longer spoken forms run first so a phrase wins over a word inside it;
/// equal lengths keep the configured order. Matching ignores case and, when
/// folding keeps UTF-16 offsets, diacritics.
public struct PersonalDictionaryReplacementApplier: Sendable {
  private let numberParser = SpokenNumberParser()

  public init() {}

  public func apply(
    _ dictionary: PersonalDictionary,
    to source: String
  ) -> String {
    dictionary.replacements.enumerated()
      .sorted {
        if $0.element.spokenForm.count != $1.element.spokenForm.count {
          return $0.element.spokenForm.count > $1.element.spokenForm.count
        }
        return $0.offset < $1.offset
      }
      .map(\.element)
      .reduce(source) { text, replacement in
        apply(replacement, to: text)
      }
  }

  private func apply(
    _ entry: PersonalDictionaryReplacement,
    to text: String
  ) -> String {
    let spokenForm = entry.spokenForm.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !spokenForm.isEmpty, entry.hasValidPattern else {
      return text
    }
    let spoken = DictionaryTemplateSegment.parse(
      spokenForm.folding(options: .diacriticInsensitive, locale: nil)
    )
    guard
      let expression = try? NSRegularExpression(
        pattern: DictionaryPatternBuilder.spokenPattern(spoken),
        options: [.caseInsensitive]
      )
    else {
      return text
    }
    let folded = text.folding(options: .diacriticInsensitive, locale: nil)
    // Folding can merge combining marks; only reuse offsets when it did not.
    let searchable = folded.utf16.count == text.utf16.count ? folded : text
    let searchableText = searchable as NSString
    let replacement = DictionaryTemplateSegment.parse(entry.replacement)
    let slotIsLast = spoken.last?.slot != nil

    var edits: [(range: NSRange, text: String)] = []
    var location = 0
    while location < searchableText.length,
      let match = expression.firstMatch(
        in: searchable,
        options: [.withTransparentBounds],
        range: NSRange(
          location: location,
          length: searchableText.length - location
        )
      )
    {
      if entry.spokenSlots.isEmpty {
        edits.append((match.range, entry.replacement))
        location = NSMaxRange(match.range)
        continue
      }
      guard
        let edit = slotEdit(
          match,
          in: searchableText,
          replacement: replacement,
          slotIsLast: slotIsLast
        )
      else {
        location = NSMaxRange(
          searchableText.rangeOfComposedCharacterSequence(
            at: match.range.location
          )
        )
        continue
      }
      edits.append(edit)
      location = NSMaxRange(edit.range)
    }

    let result = NSMutableString(string: text)
    for edit in edits.reversed() {
      result.replaceCharacters(in: edit.range, with: edit.text)
    }
    return result as String
  }

  /// Renders one slot match, or nil when its span is not a whole number.
  private func slotEdit(
    _ match: NSTextCheckingResult,
    in text: NSString,
    replacement: [DictionaryTemplateSegment],
    slotIsLast: Bool
  ) -> (range: NSRange, text: String)? {
    let slotRange = match.range(at: 1)
    guard slotRange.location != NSNotFound else {
      return nil
    }
    guard
      let words = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
    else {
      return nil
    }
    let tokens = words.matches(in: text as String, range: slotRange)
      .map(\.range)
    guard
      let number = numberParser.parsePrefix(
        tokens.map { text.substring(with: $0) }
      )
    else {
      return nil
    }
    var range = match.range
    if number.consumedTokenCount < tokens.count {
      // Leftover words such as "and" can only be dropped from a trailing slot.
      guard slotIsLast else {
        return nil
      }
      let end = NSMaxRange(tokens[number.consumedTokenCount - 1])
      range.length = end - range.location
    }
    let rendered = replacement.map { segment in
      switch segment {
      case .text(let text): text
      case .slot(.number): number.digits
      }
    }.joined()
    return (range, rendered)
  }
}
