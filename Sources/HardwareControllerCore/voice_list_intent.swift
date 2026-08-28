import Foundation

public enum VoiceListIntent: String, Codable, Equatable, Sendable {
  case none
  case unordered
  case ordered
}

public struct VoiceListIntentDetector: Sendable {
  public init() {}

  public func detect(in text: String) -> VoiceListIntent {
    guard !text.isEmpty else {
      return .none
    }
    if contains(#"(?m)^\s*\d+\.\s+\S"#, in: text)
      || containsSequentialOrdinals(in: text)
    {
      return .ordered
    }
    if contains(#"(?m)^\s*[-*•]\s+\S"#, in: text) {
      return .unordered
    }
    let hasListCue = contains(
      #"(?i)\b(?:(?:grocery|shopping|packing|task|to-do)\s+)?list\b"#,
      in: text
    )
    let hasDelimitedItems =
      text.contains(";")
      || text.filter({ $0 == "," }).count >= 2
      || (text.contains(":") && text.contains(","))
    return hasListCue && hasDelimitedItems ? .unordered : .none
  }

  private func containsSequentialOrdinals(in text: String) -> Bool {
    guard
      let first = text.range(
        of: #"\bfirst\b"#,
        options: [.regularExpression, .caseInsensitive]
      ),
      let second = text.range(
        of: #"\bsecond\b"#,
        options: [.regularExpression, .caseInsensitive],
        range: first.upperBound..<text.endIndex
      )
    else {
      return false
    }
    return second.lowerBound > first.upperBound
  }

  private func contains(_ pattern: String, in text: String) -> Bool {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return false
    }
    return expression.firstMatch(
      in: text,
      range: NSRange(text.startIndex..., in: text)
    ) != nil
  }
}
