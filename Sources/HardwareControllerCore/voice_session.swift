import Foundation

public enum VoiceSessionDeliveryOutcome:
  String,
  Codable,
  Equatable,
  Sendable
{
  case inserted
  case failed
  case notAttempted
}

/// Preserves each final text stage without conflating model output and delivery.
public struct VoiceSessionDocument: Codable, Equatable, Sendable {
  public let id: UUID
  public let startedAt: Date
  public let endedAt: Date
  public let rawText: String
  public let editedText: String
  public let formattedText: String
  public let deliveredText: String
  public let targetApplicationName: String?
  public let deliveryOutcome: VoiceSessionDeliveryOutcome
  public let deliveryFailure: String?

  public init(
    id: UUID,
    startedAt: Date,
    endedAt: Date,
    rawText: String,
    editedText: String,
    formattedText: String,
    deliveredText: String,
    targetApplicationName: String?,
    deliveryOutcome: VoiceSessionDeliveryOutcome,
    deliveryFailure: String? = nil
  ) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.rawText = rawText
    self.editedText = editedText
    self.formattedText = formattedText
    self.deliveredText = deliveredText
    self.targetApplicationName = targetApplicationName
    self.deliveryOutcome = deliveryOutcome
    self.deliveryFailure = deliveryFailure
  }
}
