import Foundation

public struct VoiceFormattedTextRenderer: Sendable {
  public init() {}

  public func render(
    _ document: VoiceFormattedDocument,
    supportsMultiline: Bool
  ) throws -> String {
    try validate(document)
    if supportsMultiline {
      return document.blocks.map(multilineText).joined(separator: "\n\n")
    }
    return document.blocks.map(singleLineText).joined(separator: " ")
  }

  private func validate(_ document: VoiceFormattedDocument) throws {
    guard document.style.revision == VoiceStyle.currentRevision else {
      throw VoiceFormattingError.unsupportedStyleRevision(
        document.style.revision
      )
    }
    guard !document.blocks.isEmpty else {
      throw VoiceFormattingError.invalidBlock
    }
    for block in document.blocks {
      guard !block.items.isEmpty,
        block.items.allSatisfy({ !$0.isEmpty }),
        !block.evidenceIndices.isEmpty,
        block.evidenceIndices.allSatisfy({
          document.evidence.indices.contains($0)
        })
      else {
        throw VoiceFormattingError.invalidEvidenceReference
      }
      guard
        block.items.allSatisfy({ item in
          item.unicodeScalars.allSatisfy {
            (block.kind == .verbatim && $0 == "\n")
              || !CharacterSet.controlCharacters.contains($0)
          }
        })
      else {
        throw VoiceFormattingError.unsafeControlCharacter
      }
    }
    guard
      document.evidence.allSatisfy({ item in
        item.rawUTF8StartOffset >= 0
          && item.rawUTF8EndOffset >= item.rawUTF8StartOffset
          && item.rawUTF8EndOffset <= document.rawText.utf8.count
      })
    else {
      throw VoiceFormattingError.invalidEvidenceReference
    }
  }

  private func multilineText(_ block: VoiceFormattedBlock) -> String {
    switch block.kind {
    case .paragraph:
      block.items.joined(separator: " ")
    case .unorderedList:
      block.items.map { "- \($0)" }.joined(separator: "\n")
    case .orderedList:
      block.items.enumerated().map { index, item in
        "\(index + 1). \(item)"
      }.joined(separator: "\n")
    case .verbatim:
      block.items.joined()
    }
  }

  private func singleLineText(_ block: VoiceFormattedBlock) -> String {
    switch block.kind {
    case .paragraph:
      block.items.joined(separator: " ")
    case .unorderedList:
      block.items.joined(separator: "; ")
    case .orderedList:
      block.items.enumerated().map { index, item in
        "\(index + 1). \(item)"
      }.joined(separator: "; ")
    case .verbatim:
      block.items.joined().split(
        whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" }
      ).joined(separator: " ")
    }
  }
}
