import Foundation

/// A typed placeholder a Dictionary replacement captures and re-renders.
public enum DictionaryReplacementSlot: String, CaseIterable, Sendable {
  /// Spoken English numbers or numerals, rendered as digits.
  case number

  public var placeholder: String { "{\(rawValue)}" }
}

public enum DictionaryReplacementPatternError: Error, Equatable, Sendable {
  /// A spoken form made only of slots would rewrite every number.
  case spokenFormNeedsWords
  case repeatedSlot(DictionaryReplacementSlot)
  case slotMissingFromSpokenForm(DictionaryReplacementSlot)
}

/// One literal run or slot of a spoken form or replacement.
enum DictionaryTemplateSegment: Equatable, Sendable {
  case text(String)
  case slot(DictionaryReplacementSlot)

  /// Splits a template at slot placeholders, dropping empty text runs.
  static func parse(_ template: String) -> [DictionaryTemplateSegment] {
    var segments: [DictionaryTemplateSegment] = []
    var remainder = template[...]
    while let next = DictionaryReplacementSlot.allCases.compactMap({ slot in
      remainder.range(of: slot.placeholder, options: .caseInsensitive)
        .map { (slot: slot, range: $0) }
    }).min(by: { $0.range.lowerBound < $1.range.lowerBound }) {
      if next.range.lowerBound > remainder.startIndex {
        segments.append(.text(String(remainder[..<next.range.lowerBound])))
      }
      segments.append(.slot(next.slot))
      remainder = remainder[next.range.upperBound...]
    }
    if !remainder.isEmpty {
      segments.append(.text(String(remainder)))
    }
    return segments
  }

  var slot: DictionaryReplacementSlot? {
    if case .slot(let slot) = self { slot } else { nil }
  }

  var text: String? {
    if case .text(let text) = self { text } else { nil }
  }
}

extension PersonalDictionaryReplacement {
  /// Slots this entry captures; an entry without them is an exact replacement.
  public var spokenSlots: [DictionaryReplacementSlot] {
    DictionaryTemplateSegment.parse(spokenForm).compactMap(\.slot)
  }

  public func validatePattern() throws(DictionaryReplacementPatternError) {
    let spoken = DictionaryTemplateSegment.parse(spokenForm)
    let slots = spoken.compactMap(\.slot)
    if !slots.isEmpty,
      !spoken.contains(where: {
        $0.text?.contains { !$0.isWhitespace } == true
      })
    {
      throw .spokenFormNeedsWords
    }
    var seen: Set<DictionaryReplacementSlot> = []
    for slot in slots where !seen.insert(slot).inserted {
      throw .repeatedSlot(slot)
    }
    for segment in DictionaryTemplateSegment.parse(replacement) {
      if let slot = segment.slot, !seen.contains(slot) {
        throw .slotMissingFromSpokenForm(slot)
      }
    }
  }

  public var hasValidPattern: Bool {
    do {
      try validatePattern()
      return true
    } catch {
      return false
    }
  }

  /// The replacement's fixed words, for checks that compare vocabulary.
  public var replacementTerm: String {
    guard !spokenSlots.isEmpty else {
      return replacement
    }
    return DictionaryTemplateSegment.parse(replacement)
      .compactMap(\.text)
      .joined(separator: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  /// Text this entry would have produced in `source`, so later stages can
  /// protect it. An exact entry always reports its replacement.
  public func outputs(in source: String) -> [String] {
    guard !spokenSlots.isEmpty else {
      return [replacement]
    }
    guard
      hasValidPattern,
      let expression = try? NSRegularExpression(
        pattern: DictionaryPatternBuilder.renderedPattern(
          DictionaryTemplateSegment.parse(replacement)
        ),
        options: [.caseInsensitive]
      )
    else {
      return []
    }
    let range = NSRange(source.startIndex..., in: source)
    return expression.matches(in: source, range: range).compactMap {
      Range($0.range, in: source).map { String(source[$0]) }
    }
  }
}

extension PersonalDictionary {
  /// Replacement text to protect from casing and model edits in `source`.
  public func replacementOutputs(in source: String) -> [String] {
    replacements.flatMap { $0.outputs(in: source) }
  }
}

/// Compiles templates into regular expressions with Dictionary word rules.
enum DictionaryPatternBuilder {
  static let boundaryBefore = #"(?<![\p{L}\p{N}_])"#
  static let boundaryAfter = #"(?![\p{L}\p{N}_])"#

  /// Matches what a recognizer may emit for a spoken form. Capture group 1
  /// holds the slot span when the form has one.
  static func spokenPattern(_ segments: [DictionaryTemplateSegment]) -> String {
    pattern(segments) { segment in
      switch segment {
      case .text(let text):
        spokenWords(text.split(whereSeparator: \.isWhitespace).map(String.init))
      case .slot(.number):
        numberCapture
      }
    }
  }

  /// Matches a replacement after rendering, with each slot as its output.
  static func renderedPattern(_ segments: [DictionaryTemplateSegment]) -> String {
    pattern(segments) { segment in
      switch segment {
      case .text(let text):
        text.split(whereSeparator: \.isWhitespace)
          .map { NSRegularExpression.escapedPattern(for: String($0)) }
          .joined(separator: #"\s+"#)
      case .slot(.number):
        #"\d+"#
      }
    }
  }

  private static func pattern(
    _ segments: [DictionaryTemplateSegment],
    body: (DictionaryTemplateSegment) -> String
  ) -> String {
    var pattern = boundaryBefore
    for (index, segment) in segments.enumerated() {
      pattern += body(segment)
      guard index + 1 < segments.count else {
        continue
      }
      // Spacing written in the template is required; its absence allows "v2".
      let spaced =
        segment.text?.last?.isWhitespace == true
        || segments[index + 1].text?.first?.isWhitespace == true
      pattern += spaced ? #"\s+"# : #"\s*"#
    }
    return pattern + boundaryAfter
  }

  /// Escapes words, letting acronyms and spelled letters match "PR", "P R",
  /// and "P.R." alike.
  private static func spokenWords(_ words: [String]) -> String {
    var parts: [String] = []
    var index = 0
    while index < words.count {
      let letters = words[index...].prefix(while: isSingleLetter)
      if letters.count >= 2 {
        parts.append(spelled(letters.compactMap(\.first)))
        index += letters.count
        continue
      }
      let word = words[index]
      parts.append(
        isAcronym(word)
          ? spelled(Array(word))
          : NSRegularExpression.escapedPattern(for: word)
      )
      index += 1
    }
    return parts.joined(separator: #"\s+"#)
  }

  /// A lazy final period stays with the sentence unless a slot needs it gone.
  private static func spelled(_ letters: [Character]) -> String {
    letters.map { NSRegularExpression.escapedPattern(for: String($0)) }
      .joined(separator: #"(?:\.\s*|\s+)?"#) + #"\.??"#
  }

  private static func isSingleLetter(_ word: String) -> Bool {
    word.count == 1 && word.allSatisfy(\.isLetter)
  }

  private static func isAcronym(_ word: String) -> Bool {
    (2...8).contains(word.count)
      && word.allSatisfy { $0.isLetter && $0.isUppercase }
  }

  private static let numberCapture: String = {
    let word =
      "(?:"
      + SpokenNumberParser.vocabulary
      .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
      .joined(separator: "|")
      + ")" + boundaryAfter
    return #"(\d+|"# + word + #"(?:(?:\s*-\s*|\s+)"# + word + ")*)"
  }()
}
