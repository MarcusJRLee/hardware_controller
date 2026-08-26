import Foundation

public enum VoiceHistoryTextStage:
  String,
  CaseIterable,
  Codable,
  Equatable,
  Sendable
{
  case raw
  case edited
  case formatted
  case delivered
  case corrected
}

public enum VoiceHistoryResultOrigin:
  String,
  Codable,
  Equatable,
  Sendable
{
  case capture
  case spokenEdits
  case formatting
  case delivery
  case correction
  case retranscription
  case reformatting
  case redelivery
}

/// Maps one immutable text range to the retained session audio timeline.
public struct VoiceHistoryTimedSpan: Codable, Equatable, Sendable {
  public let startMilliseconds: Int64
  public let endMilliseconds: Int64
  public let text: String

  public init(
    startMilliseconds: Int64,
    endMilliseconds: Int64,
    text: String
  ) {
    self.startMilliseconds = startMilliseconds
    self.endMilliseconds = endMilliseconds
    self.text = text
  }
}

/// Preserves one stage execution without replacing earlier session evidence.
public struct VoiceHistoryResult:
  Codable,
  Equatable,
  Identifiable,
  Sendable
{
  public let id: UUID
  public let sessionID: UUID
  public let createdAt: Date
  public let stage: VoiceHistoryTextStage
  public let origin: VoiceHistoryResultOrigin
  public let text: String
  public let sourceResultID: UUID?
  public let style: VoiceStyle?
  public let provider: LocalAIProviderKind?
  public let modelIdentifier: String?
  public let promptRevision: Int?
  public let formattedDocument: VoiceFormattedDocument?
  public let timedSpans: [VoiceHistoryTimedSpan]
  public let deliveryOutcome: VoiceSessionDeliveryOutcome?
  public let deliveryFailure: String?
  public let deliveryFailureReason: VoiceSessionDeliveryFailureReason?

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    createdAt: Date,
    stage: VoiceHistoryTextStage,
    origin: VoiceHistoryResultOrigin,
    text: String,
    sourceResultID: UUID?,
    style: VoiceStyle? = nil,
    provider: LocalAIProviderKind? = nil,
    modelIdentifier: String? = nil,
    promptRevision: Int? = nil,
    formattedDocument: VoiceFormattedDocument? = nil,
    timedSpans: [VoiceHistoryTimedSpan] = [],
    deliveryOutcome: VoiceSessionDeliveryOutcome? = nil,
    deliveryFailure: String? = nil,
    deliveryFailureReason: VoiceSessionDeliveryFailureReason? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.stage = stage
    self.origin = origin
    self.text = text
    self.sourceResultID = sourceResultID
    self.style = style
    self.provider = provider
    self.modelIdentifier = modelIdentifier
    self.promptRevision = promptRevision
    self.formattedDocument = formattedDocument
    self.timedSpans = timedSpans
    self.deliveryOutcome = deliveryOutcome
    self.deliveryFailure = deliveryFailure
    self.deliveryFailureReason = deliveryFailureReason
  }
}

extension Array where Element == VoiceHistoryResult {
  /// Chooses the newest nonempty reusable stage in archive order.
  public var preferredReusableResult: VoiceHistoryResult? {
    last {
      !$0.text.isEmpty
        && [
          VoiceHistoryTextStage.raw,
          .edited,
          .formatted,
          .delivered,
          .corrected,
        ].contains($0.stage)
    }
  }
}
