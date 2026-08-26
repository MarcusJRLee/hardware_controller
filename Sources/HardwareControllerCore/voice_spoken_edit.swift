public enum VoiceSpokenEditOperationKind:
  String,
  Codable,
  Equatable,
  Sendable
{
  case deleteCurrentClause
  case deleteCurrentSentence
  case insertParagraphBreak
  case beginOrderedList
  case beginOrderedListItem
  case endList
  case preserveLiteralCommand
}

public struct VoiceSpokenEditOperation: Codable, Equatable, Sendable {
  public let kind: VoiceSpokenEditOperationKind
  public let sourceUTF8StartOffset: Int
  public let sourceUTF8EndOffset: Int
  public let editedUTF8StartOffset: Int
  public let editedUTF8EndOffset: Int
  public let replacementText: String

  public init(
    kind: VoiceSpokenEditOperationKind,
    sourceUTF8StartOffset: Int,
    sourceUTF8EndOffset: Int,
    editedUTF8StartOffset: Int,
    editedUTF8EndOffset: Int,
    replacementText: String
  ) {
    self.kind = kind
    self.sourceUTF8StartOffset = sourceUTF8StartOffset
    self.sourceUTF8EndOffset = sourceUTF8EndOffset
    self.editedUTF8StartOffset = editedUTF8StartOffset
    self.editedUTF8EndOffset = editedUTF8EndOffset
    self.replacementText = replacementText
  }
}

public struct VoiceSpokenEditResult: Codable, Equatable, Sendable {
  public static let currentRevision = 1

  public let revision: Int
  public let sourceText: String
  public let editedText: String
  public let operations: [VoiceSpokenEditOperation]

  public init(
    revision: Int = currentRevision,
    sourceText: String,
    editedText: String,
    operations: [VoiceSpokenEditOperation]
  ) {
    self.revision = revision
    self.sourceText = sourceText
    self.editedText = editedText
    self.operations = operations
  }
}

public enum VoiceSpokenEditError: Error, Equatable, Sendable {
  case unsupportedRevision(Int)
  case invalidSourceRange
  case operationsOutOfOrder
  case invalidEditedRange
  case invalidReplacement
  case invalidCommandEvidence
  case nonCanonicalOperations
  case resultMismatch
}

extension String {
  func voiceUTF8Offset(of index: String.Index) -> Int {
    self[..<index].utf8.count
  }

  func voiceIndex(atUTF8Offset offset: Int) -> String.Index? {
    guard offset >= 0,
      let utf8Index = utf8.index(
        utf8.startIndex,
        offsetBy: offset,
        limitedBy: utf8.endIndex
      )
    else {
      return nil
    }
    return String.Index(utf8Index, within: self)
  }
}
