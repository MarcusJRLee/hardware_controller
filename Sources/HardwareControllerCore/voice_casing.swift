import Foundation

public enum VoiceCasingPolicy:
  String,
  CaseIterable,
  Codable,
  Equatable,
  Sendable
{
  case styleDefault
  case lowercaseProse
  case strictLowercase
}

public struct VoiceCasingTransformer: Sendable {
  public init() {}

  public func apply(
    _ policy: VoiceCasingPolicy,
    to text: String,
    preserving source: String,
    dictionary: PersonalDictionary
  ) -> String {
    guard policy != .styleDefault else {
      return text
    }
    let protectedTokens = intentionalTokens(
      in: source,
      dictionary: dictionary,
      preserveProseCasing: policy == .lowercaseProse
    )
    let ranges = nonoverlappingRanges(
      of: protectedTokens,
      in: text
    )
    var result = ""
    var cursor = text.startIndex
    for range in ranges {
      result += text[cursor..<range.lowerBound].lowercased()
      result += text[range]
      cursor = range.upperBound
    }
    result += text[cursor...].lowercased()
    return result
  }

  private func intentionalTokens(
    in source: String,
    dictionary: PersonalDictionary,
    preserveProseCasing: Bool
  ) -> [String] {
    let patterns = [
      #"https?://[^\s]+"#,
      #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#,
      #"(?:/[^\s/]+){2,}"#,
      #"\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+\b"#,
      #"\b[a-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*\b"#,
      #"\b[A-Z][a-z]+(?:[A-Z][A-Za-z0-9]*)+\b"#,
      #"[\"“][^\"”]+[\"”]"#,
    ]
    var tokens = Set(
      patterns.flatMap { matches(pattern: $0, in: source) }
    )
    tokens.formUnion(dictionary.vocabulary)
    tokens.formUnion(dictionary.replacements.map(\.replacement))
    if preserveProseCasing {
      tokens.formUnion(matches(pattern: #"\b[A-Z]{2,}\b"#, in: source))
      tokens.formUnion(sourceSignaledNames(in: source))
    }
    return tokens.filter { !$0.isEmpty }.sorted {
      if $0.count != $1.count {
        return $0.count > $1.count
      }
      return $0 < $1
    }
  }

  private func sourceSignaledNames(in source: String) -> [String] {
    guard
      let expression = try? NSRegularExpression(
        pattern: #"\b[A-Z][a-z]+\b"#
      )
    else {
      return []
    }
    let range = NSRange(source.startIndex..., in: source)
    return expression.matches(in: source, range: range).compactMap { match in
      guard let wordRange = Range(match.range, in: source) else {
        return nil
      }
      let prefix = source[..<wordRange.lowerBound]
      guard let preceding = prefix.last(where: { !$0.isWhitespace }) else {
        return nil
      }
      guard !".!?".contains(preceding) else {
        return nil
      }
      return String(source[wordRange])
    }
  }

  private func matches(
    pattern: String,
    in source: String
  ) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return []
    }
    let range = NSRange(source.startIndex..., in: source)
    return expression.matches(in: source, range: range).compactMap { match in
      Range(match.range, in: source).map { String(source[$0]) }
    }
  }

  private func nonoverlappingRanges(
    of tokens: [String],
    in text: String
  ) -> [Range<String.Index>] {
    let candidates = tokens.flatMap { token in
      ranges(of: token, in: text)
    }.sorted {
      if $0.lowerBound != $1.lowerBound {
        return $0.lowerBound < $1.lowerBound
      }
      return text.distance(from: $0.lowerBound, to: $0.upperBound)
        > text.distance(from: $1.lowerBound, to: $1.upperBound)
    }
    var selected: [Range<String.Index>] = []
    for candidate in candidates
    where selected.last?.upperBound ?? text.startIndex <= candidate.lowerBound {
      selected.append(candidate)
    }
    return selected
  }

  private func ranges(
    of token: String,
    in text: String
  ) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
      let range = text.range(
        of: token,
        range: searchStart..<text.endIndex
      )
    {
      ranges.append(range)
      searchStart = range.upperBound
    }
    return ranges
  }
}
