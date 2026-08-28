import Foundation

public struct VoiceFormattedDocumentBuilder: Sendable {
  public init() {}

  public func build(
    formattedText: String,
    rawText: String,
    style: VoiceStyle,
    provider: LocalAIProviderKind? = nil,
    modelIdentifier: String? = nil,
    promptRevision: Int? = nil,
    validationStatus: VoiceFormattingValidationStatus = .validated
  ) throws -> VoiceFormattedDocument {
    guard style.revision == VoiceStyle.currentRevision else {
      throw VoiceFormattingError.unsupportedStyleRevision(style.revision)
    }
    guard
      formattedText.unicodeScalars.allSatisfy({ scalar in
        scalar == "\n" || !CharacterSet.controlCharacters.contains(scalar)
      })
    else {
      throw VoiceFormattingError.unsafeControlCharacter
    }
    let normalized = formattedText.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !normalized.isEmpty else {
      throw VoiceFormattingError.emptyFormattedText
    }

    let evidence = VoiceFormattingEvidence(
      rawUTF8StartOffset: 0,
      rawUTF8EndOffset: rawText.utf8.count,
      provider: provider,
      modelIdentifier: modelIdentifier,
      promptRevision: promptRevision
    )
    let blocks =
      style.kind == .verbatim
      ? [
        VoiceFormattedBlock(
          kind: .verbatim,
          items: [normalized],
          evidenceIndices: [0]
        )
      ]
      : try parse(normalized, rawText: rawText)
    return VoiceFormattedDocument(
      rawText: rawText,
      style: style,
      blocks: blocks,
      evidence: [evidence],
      validationStatus: validationStatus
    )
  }

  private func parse(
    _ text: String,
    rawText: String
  ) throws -> [VoiceFormattedBlock] {
    if let ordinalCount = sequentialOrdinalCount(rawText),
      let ordinalBlocks = ordinalBlocks(
        text,
        expectedCount: ordinalCount
      )
    {
      return ordinalBlocks
    }
    var blocks: [VoiceFormattedBlock] = []
    var currentKind: VoiceFormattedBlockKind?
    var currentItems: [String] = []

    func flush() throws {
      guard let currentKind else {
        return
      }
      guard !currentItems.isEmpty else {
        throw VoiceFormattingError.invalidBlock
      }
      blocks.append(
        VoiceFormattedBlock(
          kind: currentKind,
          items: currentItems,
          evidenceIndices: [0]
        )
      )
    }

    for rawLine in text.split(
      separator: "\n",
      omittingEmptySubsequences: false
    ) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else {
        try flush()
        currentKind = nil
        currentItems = []
        continue
      }
      let parsed = parsedLine(line)
      guard !parsed.text.isEmpty else {
        throw VoiceFormattingError.invalidBlock
      }
      if currentKind != parsed.kind {
        try flush()
        currentKind = parsed.kind
        currentItems = []
      }
      if parsed.kind == .paragraph, !currentItems.isEmpty {
        currentItems[currentItems.count - 1] += " " + parsed.text
      } else {
        currentItems.append(parsed.text)
      }
    }
    try flush()
    guard !blocks.isEmpty else {
      throw VoiceFormattingError.invalidBlock
    }
    return blocks
  }

  private func sequentialOrdinalCount(_ text: String) -> Int? {
    let ordinals = ordinalMatches(in: text).map(\.ordinal)
    guard ordinals.count >= 2,
      ordinals == Array(0..<ordinals.count)
    else {
      return nil
    }
    return ordinals.count
  }

  private func ordinalBlocks(
    _ text: String,
    expectedCount: Int
  ) -> [VoiceFormattedBlock]? {
    guard !text.contains("\n") else {
      return nil
    }
    let matches = ordinalMatches(in: text)
    guard matches.count == expectedCount,
      matches.map(\.ordinal) == Array(0..<expectedCount)
    else {
      return nil
    }

    var blocks: [VoiceFormattedBlock] = []
    let prefix = String(text[..<matches[0].range.lowerBound])
      .trimmingCharacters(in: .whitespaces)
    if !prefix.isEmpty {
      blocks.append(
        VoiceFormattedBlock(
          kind: .paragraph,
          items: [prefix],
          evidenceIndices: [0]
        )
      )
    }
    let items = matches.indices.map { index in
      let end =
        index + 1 < matches.count
        ? matches[index + 1].range.lowerBound : text.endIndex
      return String(text[matches[index].range.upperBound..<end])
        .trimmingCharacters(in: Self.ordinalItemSeparators)
    }
    guard items.allSatisfy({ !$0.isEmpty }) else {
      return nil
    }
    blocks.append(
      VoiceFormattedBlock(
        kind: .orderedList,
        items: items,
        evidenceIndices: [0]
      )
    )
    return blocks
  }

  private func ordinalMatches(
    in text: String
  ) -> [(range: Range<String.Index>, ordinal: Int)] {
    let words = [
      "first", "second", "third", "fourth", "fifth",
      "sixth", "seventh", "eighth", "ninth", "tenth",
    ]
    guard
      let expression = try? NSRegularExpression(
        pattern: "(?i)\\b(\(words.joined(separator: "|")))\\b[,]?"
      )
    else {
      return []
    }
    let fullRange = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: fullRange).compactMap {
      match in
      guard
        let range = Range(match.range, in: text),
        let wordRange = Range(match.range(at: 1), in: text),
        let ordinal = words.firstIndex(of: text[wordRange].lowercased())
      else {
        return nil
      }
      return (range, ordinal)
    }
  }

  private static let ordinalItemSeparators = CharacterSet.whitespaces
    .union(CharacterSet(charactersIn: ";,:"))

  private func parsedLine(
    _ line: String
  ) -> (kind: VoiceFormattedBlockKind, text: String) {
    for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
      return (.unorderedList, String(line.dropFirst(prefix.count)))
    }
    if let markerEnd = line.firstIndex(of: "."),
      markerEnd < line.endIndex,
      line.index(after: markerEnd) < line.endIndex,
      line[line.index(after: markerEnd)] == " ",
      !line[..<markerEnd].isEmpty,
      line[..<markerEnd].allSatisfy(\.isNumber)
    {
      let contentStart = line.index(markerEnd, offsetBy: 2)
      return (.orderedList, String(line[contentStart...]))
    }
    return (.paragraph, line)
  }
}
