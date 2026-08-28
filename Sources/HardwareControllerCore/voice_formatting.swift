public enum VoiceStyleKind:
  String,
  CaseIterable,
  Codable,
  Equatable,
  Hashable,
  Sendable
{
  case natural
  case casualMessage
  case formal
  case technical
  case verbatim
}

public struct VoiceStyle: Codable, Equatable, Hashable, Sendable {
  public static let currentRevision = 1

  public let kind: VoiceStyleKind
  public let revision: Int

  public init(
    kind: VoiceStyleKind,
    revision: Int = currentRevision
  ) {
    self.kind = kind
    self.revision = revision
  }

  public static let natural = VoiceStyle(kind: .natural)
  public static let casualMessage = VoiceStyle(kind: .casualMessage)
  public static let formal = VoiceStyle(kind: .formal)
  public static let technical = VoiceStyle(kind: .technical)
  public static let verbatim = VoiceStyle(kind: .verbatim)
}

public enum VoiceFormattingDraftBlockKind:
  String,
  Codable,
  Equatable,
  Hashable,
  Sendable
{
  case paragraph
  case unorderedList
  case orderedList
}

public struct VoiceFormattingDraftBlock: Codable, Equatable, Sendable {
  public let kind: VoiceFormattingDraftBlockKind
  public let items: [String]

  public init(
    kind: VoiceFormattingDraftBlockKind,
    items: [String]
  ) {
    self.kind = kind
    self.items = items
  }
}

public struct VoiceFormattingDraft: Codable, Equatable, Sendable {
  public let blocks: [VoiceFormattingDraftBlock]

  public init(blocks: [VoiceFormattingDraftBlock]) {
    self.blocks = blocks
  }

  public static func paragraph(_ text: String) -> VoiceFormattingDraft {
    VoiceFormattingDraft(
      blocks: [
        VoiceFormattingDraftBlock(
          kind: .paragraph,
          items: [text]
        )
      ]
    )
  }
}

public enum VoiceFormattedBlockKind:
  String,
  Codable,
  Equatable,
  Sendable
{
  case paragraph
  case unorderedList
  case orderedList
  case verbatim
}

public struct VoiceFormattedBlock: Codable, Equatable, Sendable {
  public let kind: VoiceFormattedBlockKind
  public let items: [String]
  public let evidenceIndices: [Int]

  public init(
    kind: VoiceFormattedBlockKind,
    items: [String],
    evidenceIndices: [Int]
  ) {
    self.kind = kind
    self.items = items
    self.evidenceIndices = evidenceIndices
  }
}

public struct VoiceFormattingEvidence: Codable, Equatable, Sendable {
  public let rawUTF8StartOffset: Int
  public let rawUTF8EndOffset: Int
  public let provider: LocalAIProviderKind?
  public let modelIdentifier: String?
  public let promptRevision: Int?

  public init(
    rawUTF8StartOffset: Int,
    rawUTF8EndOffset: Int,
    provider: LocalAIProviderKind?,
    modelIdentifier: String?,
    promptRevision: Int?
  ) {
    self.rawUTF8StartOffset = rawUTF8StartOffset
    self.rawUTF8EndOffset = rawUTF8EndOffset
    self.provider = provider
    self.modelIdentifier = modelIdentifier
    self.promptRevision = promptRevision
  }
}

public enum VoiceFormattingValidationStatus:
  String,
  Codable,
  Equatable,
  Sendable
{
  case validated
  case sourceFallback = "rawFallback"
}

public struct VoiceFormattedDocument: Codable, Equatable, Sendable {
  public let rawText: String
  public let style: VoiceStyle
  public let blocks: [VoiceFormattedBlock]
  public let evidence: [VoiceFormattingEvidence]
  public let validationStatus: VoiceFormattingValidationStatus

  public init(
    rawText: String,
    style: VoiceStyle,
    blocks: [VoiceFormattedBlock],
    evidence: [VoiceFormattingEvidence],
    validationStatus: VoiceFormattingValidationStatus
  ) {
    self.rawText = rawText
    self.style = style
    self.blocks = blocks
    self.evidence = evidence
    self.validationStatus = validationStatus
  }
}

public enum VoiceFormattingError: Error, Equatable, Sendable {
  case unsupportedStyleRevision(Int)
  case emptyFormattedText
  case unsafeControlCharacter
  case invalidBlock
  case invalidEvidenceReference
}
