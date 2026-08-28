import Foundation

public struct VoiceFormattingDraftNormalizer: Sendable {
  public init() {}

  public func normalize(
    _ output: VoiceFormattingDraft,
    transcript: String,
    intent: VoiceListIntent
  ) -> VoiceFormattingDraft {
    let normalized: VoiceFormattingDraft?
    switch intent {
    case .none:
      normalized = nil
    case .unordered:
      normalized = unorderedDraft(from: transcript)
    case .ordered:
      normalized = orderedDraft(from: transcript)
    }
    return normalized ?? output
  }

  private func unorderedDraft(
    from transcript: String
  ) -> VoiceFormattingDraft? {
    let markerPattern = #"(?m)^\s*[-*•]\s+"#
    if !matches(markerPattern, in: transcript).isEmpty {
      return explicitlyMarkedDraft(
        from: transcript,
        markerPattern: markerPattern,
        kind: .unorderedList
      )
    }
    guard
      let cue = firstMatch(
        #"(?i)\b(?:(?:grocery|shopping|packing|task|to-do)\s+)?list\b\s*:?\s*"#,
        in: transcript
      )
    else {
      return nil
    }
    let heading = cleanHeading(
      String(transcript[..<cue.upperBound])
    )
    let remainder = transcript[cue.upperBound...]
    let items = remainder.split(whereSeparator: {
      $0 == "," || $0 == ";"
    }).compactMap { item in
      cleanItem(String(item), removeLeadingConjunction: true)
    }
    return draft(heading: heading, kind: .unorderedList, items: items)
  }

  private func orderedDraft(
    from transcript: String
  ) -> VoiceFormattingDraft? {
    let markerPattern = #"(?m)^\s*\d+[.)]\s+"#
    if !matches(markerPattern, in: transcript).isEmpty {
      return explicitlyMarkedDraft(
        from: transcript,
        markerPattern: markerPattern,
        kind: .orderedList
      )
    }
    let ordinals = matches(
      #"(?i)\b(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\b"#,
      in: transcript
    )
    guard ordinals.count >= 2 else {
      return nil
    }
    let heading = cleanHeading(
      String(transcript[..<ordinals[0].lowerBound])
    )
    let items = ordinals.indices.compactMap { index in
      let start = ordinals[index].upperBound
      let end =
        index + 1 < ordinals.count
        ? ordinals[index + 1].lowerBound : transcript.endIndex
      return cleanItem(String(transcript[start..<end]))
    }
    return draft(heading: heading, kind: .orderedList, items: items)
  }

  private func explicitlyMarkedDraft(
    from transcript: String,
    markerPattern: String,
    kind: VoiceFormattingDraftBlockKind
  ) -> VoiceFormattingDraft? {
    var headingLines: [String] = []
    var items: [String] = []
    for line in transcript.split(
      omittingEmptySubsequences: true,
      whereSeparator: { $0 == "\n" || $0 == "\r" }
    ) {
      let text = String(line)
      guard let marker = firstMatch(markerPattern, in: text) else {
        guard items.isEmpty else {
          return nil
        }
        headingLines.append(text)
        continue
      }
      if let item = cleanItem(String(text[marker.upperBound...])) {
        items.append(item)
      }
    }
    return draft(
      heading: cleanHeading(headingLines.joined(separator: " ")),
      kind: kind,
      items: items
    )
  }

  private func draft(
    heading: String?,
    kind: VoiceFormattingDraftBlockKind,
    items: [String]
  ) -> VoiceFormattingDraft? {
    guard items.count >= 2 else {
      return nil
    }
    var blocks: [VoiceFormattingDraftBlock] = []
    if let heading {
      blocks.append(
        VoiceFormattingDraftBlock(
          kind: .paragraph,
          items: [heading]
        )
      )
    }
    blocks.append(VoiceFormattingDraftBlock(kind: kind, items: items))
    return VoiceFormattingDraft(blocks: blocks)
  }

  private func cleanHeading(_ value: String) -> String? {
    let text = value.trimmingCharacters(
      in: CharacterSet(charactersIn: " \t\r\n,;:.")
    )
    return text.isEmpty ? nil : "\(text):"
  }

  private func cleanItem(
    _ value: String,
    removeLeadingConjunction: Bool = false
  ) -> String? {
    var text = value.trimmingCharacters(
      in: CharacterSet(charactersIn: " \t\r\n,;:.")
    )
    if removeLeadingConjunction,
      text.lowercased().hasPrefix("and ")
    {
      text.removeFirst(4)
    }
    return text.isEmpty ? nil : text
  }

  private func firstMatch(
    _ pattern: String,
    in text: String
  ) -> Range<String.Index>? {
    matches(pattern, in: text).first
  }

  private func matches(
    _ pattern: String,
    in text: String
  ) -> [Range<String.Index>] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return []
    }
    return expression.matches(
      in: text,
      range: NSRange(text.startIndex..., in: text)
    ).compactMap { Range($0.range, in: text) }
  }
}
