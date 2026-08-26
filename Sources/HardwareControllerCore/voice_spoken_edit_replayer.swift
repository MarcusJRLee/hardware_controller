import Foundation

public struct VoiceSpokenEditReplayer: Sendable {
  public init() {}

  public func replay(
    _ result: VoiceSpokenEditResult
  ) throws -> String {
    guard result.revision == VoiceSpokenEditResult.currentRevision else {
      throw VoiceSpokenEditError.unsupportedRevision(result.revision)
    }
    return try replay(
      sourceText: result.sourceText,
      operations: result.operations
    )
  }

  public func validate(_ result: VoiceSpokenEditResult) throws {
    guard try replay(result) == result.editedText else {
      throw VoiceSpokenEditError.resultMismatch
    }
    let canonical = VoiceSpokenEditEngine().apply(to: result.sourceText)
    guard canonical.operations == result.operations else {
      throw VoiceSpokenEditError.nonCanonicalOperations
    }
  }

  public func replay(
    sourceText: String,
    operations: [VoiceSpokenEditOperation]
  ) throws -> String {
    var sourceCursor = sourceText.startIndex
    var sourceCursorOffset = 0
    var editedText = ""

    for operation in operations {
      guard operation.sourceUTF8StartOffset >= sourceCursorOffset else {
        throw VoiceSpokenEditError.operationsOutOfOrder
      }
      guard
        let sourceStart = sourceText.voiceIndex(
          atUTF8Offset: operation.sourceUTF8StartOffset
        ),
        let sourceEnd = sourceText.voiceIndex(
          atUTF8Offset: operation.sourceUTF8EndOffset
        ),
        sourceStart >= sourceCursor,
        sourceEnd >= sourceStart
      else {
        throw VoiceSpokenEditError.invalidSourceRange
      }
      try validateCommandEvidence(
        sourceText[sourceStart..<sourceEnd],
        for: operation
      )
      editedText.append(contentsOf: sourceText[sourceCursor..<sourceStart])
      guard
        operation.editedUTF8EndOffset == editedText.utf8.count,
        operation.editedUTF8StartOffset >= 0,
        operation.editedUTF8StartOffset
          <= operation.editedUTF8EndOffset,
        let editedStart = editedText.voiceIndex(
          atUTF8Offset: operation.editedUTF8StartOffset
        )
      else {
        throw VoiceSpokenEditError.invalidEditedRange
      }
      try validateReplacement(operation)
      editedText.replaceSubrange(
        editedStart..<editedText.endIndex,
        with: operation.replacementText
      )
      sourceCursor = sourceEnd
      sourceCursorOffset = operation.sourceUTF8EndOffset
    }

    editedText.append(contentsOf: sourceText[sourceCursor...])
    guard !operations.isEmpty else {
      return editedText
    }
    return editedText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func validateReplacement(
    _ operation: VoiceSpokenEditOperation
  ) throws {
    let valid: Bool
    switch operation.kind {
    case .deleteCurrentClause, .deleteCurrentSentence:
      valid =
        operation.replacementText.isEmpty
        || operation.replacementText == " "
    case .insertParagraphBreak, .endList:
      valid = operation.replacementText == "\n\n"
    case .beginOrderedList:
      valid =
        operation.replacementText == "1. "
        || operation.replacementText == "\n\n1. "
    case .beginOrderedListItem:
      valid = isOrderedListItem(operation.replacementText)
    case .preserveLiteralCommand:
      valid =
        !operation.replacementText.isEmpty
        && operation.replacementText.unicodeScalars.allSatisfy {
          !CharacterSet.controlCharacters.contains($0)
        }
    }
    guard valid else {
      throw VoiceSpokenEditError.invalidReplacement
    }
  }

  private func validateCommandEvidence(
    _ evidence: Substring,
    for operation: VoiceSpokenEditOperation
  ) throws {
    let trimmed = evidence.trimmingCharacters(
      in: .whitespacesAndNewlines.union(Self.trailingCommandCharacters)
    )
    let words = trimmed.split(whereSeparator: { $0.isWhitespace })
    let normalized = words.joined(separator: " ").lowercased()
    let valid: Bool
    switch operation.kind {
    case .deleteCurrentClause:
      valid = normalized == "scratch that"
    case .deleteCurrentSentence:
      valid = normalized == "delete that sentence"
    case .insertParagraphBreak, .beginOrderedListItem:
      valid = normalized == "new paragraph"
    case .beginOrderedList:
      valid = normalized == "start a numbered list"
    case .endList:
      valid = normalized == "end list"
    case .preserveLiteralCommand:
      let literalWords = trimmed.split(
        maxSplits: 1,
        whereSeparator: { $0.isWhitespace }
      )
      valid =
        literalWords.count == 2
        && literalWords[0].lowercased() == "literal"
        && Self.commandPhrases.contains(
          literalWords[1].split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ").lowercased()
        )
        && String(literalWords[1]) == operation.replacementText
    }
    guard valid else {
      throw VoiceSpokenEditError.invalidCommandEvidence
    }
  }

  private func isOrderedListItem(_ value: String) -> Bool {
    guard value.hasPrefix("\n"), value.hasSuffix(". ") else {
      return false
    }
    let numberStart = value.index(after: value.startIndex)
    let numberEnd = value.index(value.endIndex, offsetBy: -2)
    guard
      let number = Int(value[numberStart..<numberEnd]),
      number >= 2
    else {
      return false
    }
    return true
  }

  private static let trailingCommandCharacters = CharacterSet(
    charactersIn: ".,;:?!"
  )
  private static let commandPhrases: Set<String> = [
    "scratch that",
    "delete that sentence",
    "new paragraph",
    "start a numbered list",
    "end list",
  ]
}
