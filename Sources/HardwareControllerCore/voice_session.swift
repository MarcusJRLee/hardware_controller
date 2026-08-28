import Foundation

public enum VoiceSessionInputKind:
  String,
  Codable,
  Equatable,
  Sendable
{
  case microphoneCapture
  case importedAudio
}

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

public enum VoiceSessionDeliveryFailureReason:
  String,
  Codable,
  Equatable,
  Sendable
{
  case focusChanged
  case processChanged
  case secureStatusChanged
  case caretChanged
  case insertionRejected

  public init?(_ failure: TranscriptionFailure) {
    switch failure {
    case .focusChanged:
      self = .focusChanged
    case .processChanged:
      self = .processChanged
    case .secureTextField:
      self = .secureStatusChanged
    case .caretChanged:
      self = .caretChanged
    case .insertionFailed:
      self = .insertionRejected
    case .microphonePermissionDenied,
      .speechRecognitionPermissionDenied,
      .localeUnsupported,
      .modelUnavailable,
      .noFocusedTextField,
      .audioUnavailable,
      .recognitionFailed:
      return nil
    }
  }
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
  public let deliveryFailureReason: VoiceSessionDeliveryFailureReason?
  public let formattedDocument: VoiceFormattedDocument?
  public let spokenEdits: VoiceSpokenEditResult?
  public let inputKind: VoiceSessionInputKind

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
    deliveryFailure: String? = nil,
    deliveryFailureReason: VoiceSessionDeliveryFailureReason? = nil,
    formattedDocument: VoiceFormattedDocument? = nil,
    spokenEdits: VoiceSpokenEditResult? = nil,
    inputKind: VoiceSessionInputKind = .microphoneCapture
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
    self.deliveryFailureReason = deliveryFailureReason
    self.formattedDocument = formattedDocument
    self.spokenEdits = spokenEdits
    self.inputKind = inputKind
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case startedAt
    case endedAt
    case rawText
    case editedText
    case formattedText
    case deliveredText
    case targetApplicationName
    case deliveryOutcome
    case deliveryFailure
    case deliveryFailureReason
    case formattedDocument
    case spokenEdits
    case inputKind
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    endedAt = try container.decode(Date.self, forKey: .endedAt)
    rawText = try container.decode(String.self, forKey: .rawText)
    editedText = try container.decode(String.self, forKey: .editedText)
    formattedText = try container.decode(String.self, forKey: .formattedText)
    deliveredText = try container.decode(String.self, forKey: .deliveredText)
    targetApplicationName = try container.decodeIfPresent(
      String.self,
      forKey: .targetApplicationName
    )
    deliveryOutcome = try container.decode(
      VoiceSessionDeliveryOutcome.self,
      forKey: .deliveryOutcome
    )
    deliveryFailure = try container.decodeIfPresent(
      String.self,
      forKey: .deliveryFailure
    )
    deliveryFailureReason = try container.decodeIfPresent(
      VoiceSessionDeliveryFailureReason.self,
      forKey: .deliveryFailureReason
    )
    formattedDocument = try container.decodeIfPresent(
      VoiceFormattedDocument.self,
      forKey: .formattedDocument
    )
    spokenEdits = try container.decodeIfPresent(
      VoiceSpokenEditResult.self,
      forKey: .spokenEdits
    )
    inputKind =
      try container.decodeIfPresent(
        VoiceSessionInputKind.self,
        forKey: .inputKind
      ) ?? .microphoneCapture
  }
}
