import Foundation

/// The digits read from the start of a token list and how many tokens they used.
public struct SpokenNumber: Equatable, Sendable {
  public let digits: String
  public let consumedTokenCount: Int

  public init(digits: String, consumedTokenCount: Int) {
    self.digits = digits
    self.consumedTokenCount = consumedTokenCount
  }
}

/// Reads an English cardinal, a digit-by-digit run, or a numeral from the
/// start of a token list.
///
/// Parsing is greedy and stops at the first token that cannot extend a valid
/// number, so trailing words such as "and" stay in the transcript.
public struct SpokenNumberParser: Sendable {
  public init() {}

  public func parsePrefix(_ rawTokens: [String]) -> SpokenNumber? {
    let tokens = rawTokens.map { $0.lowercased() }
    guard let first = tokens.first, !first.isEmpty else {
      return nil
    }
    if first.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) {
      return SpokenNumber(digits: first, consumedTokenCount: 1)
    }
    // "one two three" names digits, not a sum; at least two keep "one" a cardinal.
    let digitRun = tokens.prefix { Self.digitWords[$0] != nil }
    if digitRun.count >= 2 {
      return SpokenNumber(
        digits: digitRun.compactMap { Self.digitWords[$0] }
          .map(String.init).joined(),
        consumedTokenCount: digitRun.count
      )
    }
    if first == "zero" {
      return SpokenNumber(digits: "0", consumedTokenCount: 1)
    }
    return cardinal(tokens).map {
      SpokenNumber(digits: String($0.value), consumedTokenCount: $0.end)
    }
  }

  private func cardinal(_ tokens: [String]) -> (value: Int, end: Int)? {
    guard var group = group(tokens, from: 0) else {
      return nil
    }
    var total = 0
    var lastScale = Int.max
    while true {
      guard
        group.end < tokens.count,
        let scale = Self.scales[tokens[group.end]],
        scale < lastScale
      else {
        return (total + group.value, group.end)
      }
      total += group.value * scale
      lastScale = scale
      let afterScale = group.end + 1
      let next =
        afterScale < tokens.count && tokens[afterScale] == "and"
        ? afterScale + 1 : afterScale
      guard let following = self.group(tokens, from: next) else {
        return (total, afterScale)
      }
      group = following
    }
  }

  /// Parses a value below one thousand, including "fifteen hundred" forms.
  private func group(
    _ tokens: [String],
    from start: Int
  ) -> (value: Int, end: Int)? {
    guard let leading = belowHundred(tokens, from: start) else {
      return nil
    }
    guard leading.end < tokens.count, tokens[leading.end] == "hundred" else {
      return leading
    }
    let value = leading.value * 100
    let afterHundred = leading.end + 1
    if afterHundred < tokens.count, tokens[afterHundred] == "and",
      let rest = belowHundred(tokens, from: afterHundred + 1)
    {
      return (value + rest.value, rest.end)
    }
    if let rest = belowHundred(tokens, from: afterHundred) {
      return (value + rest.value, rest.end)
    }
    return (value, afterHundred)
  }

  private func belowHundred(
    _ tokens: [String],
    from start: Int
  ) -> (value: Int, end: Int)? {
    guard start < tokens.count else {
      return nil
    }
    let token = tokens[start]
    if let value = Self.units[token] ?? Self.teens[token] {
      return (value, start + 1)
    }
    guard let tens = Self.tens[token] else {
      return nil
    }
    if start + 1 < tokens.count, let unit = Self.units[tokens[start + 1]] {
      return (tens + unit, start + 2)
    }
    return (tens, start + 1)
  }

  private static let units: [String: Int] = [
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9,
  ]
  private static let digitWords = units.merging(["zero": 0]) { current, _ in
    current
  }
  private static let teens: [String: Int] = [
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
    "nineteen": 19,
  ]
  private static let tens: [String: Int] = [
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
  ]
  private static let scales: [String: Int] = [
    "thousand": 1_000, "million": 1_000_000,
  ]

  /// Every word the parser can consume; matchers use it to bound a number span.
  public static let vocabulary: Set<String> = Set(digitWords.keys)
    .union(teens.keys).union(tens.keys).union(scales.keys)
    .union(["hundred", "and"])
}
