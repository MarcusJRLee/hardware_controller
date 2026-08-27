import Foundation
import HardwareControllerVoiceCore

enum VoiceInputHistoryError: Error, LocalizedError, Sendable {
  case invalidLimit
  case invalidSession
  case duplicateSession
  case storageUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidLimit:
      "History queries require a limit from 1 through 1,000."
    case .invalidSession:
      "The local History session is invalid."
    case .duplicateSession:
      "This local History session already exists."
    case .storageUnavailable:
      "Local Voice History is unavailable."
    }
  }
}

struct VoiceInputHistoryAudioArtifact: Codable, Equatable, Sendable {
  let url: URL
  let byteCount: Int64
  let sha256: String
}

struct VoiceInputHistorySession: Codable, Equatable, Identifiable, Sendable {
  static let currentSchemaRevision = 2
  static let recoveryLifetime: TimeInterval = 86_400

  let schemaRevision: Int
  let id: UUID
  let startedAt: Date
  let endedAt: Date
  let rawText: String
  let editedText: String
  let formattedText: String
  let style: VoiceStyle
  let spokenEdits: VoiceSpokenEditResult
  let formattedDocument: VoiceFormattedDocument
  let timedSegments: [VoiceInputTranscriptSegment]
  let modelPackageID: String
  let modelVersion: String
  let audioArtifact: VoiceInputHistoryAudioArtifact?
  let audioExpiredAt: Date?
  let audioExpiredReason: VoiceHistoryAudioExpirationReason?
  let recoveryReason: VoiceInputCaptureInterruptionReason?

  init(
    id: UUID,
    startedAt: Date,
    endedAt: Date,
    transcript: VoiceInputProcessedTranscript,
    audioArtifact: VoiceInputHistoryAudioArtifact?,
    audioExpiredAt: Date? = nil,
    audioExpiredReason: VoiceHistoryAudioExpirationReason? = nil
  ) {
    schemaRevision = Self.currentSchemaRevision
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    rawText = transcript.rawTranscript.text
    editedText = transcript.editedText
    formattedText = transcript.formattedText
    style = transcript.formattedDocument.style
    spokenEdits = transcript.spokenEdits
    formattedDocument = transcript.formattedDocument
    timedSegments = transcript.rawTranscript.segments
    modelPackageID = transcript.rawTranscript.modelPackageID
    modelVersion = transcript.rawTranscript.modelVersion
    self.audioArtifact = audioArtifact
    self.audioExpiredAt = audioExpiredAt
    self.audioExpiredReason = audioExpiredReason
    recoveryReason = nil
  }

  init(
    recoveryID: UUID,
    startedAt: Date,
    endedAt: Date,
    reason: VoiceInputCaptureInterruptionReason,
    audioArtifact: VoiceInputHistoryAudioArtifact
  ) {
    schemaRevision = Self.currentSchemaRevision
    id = recoveryID
    self.startedAt = startedAt
    self.endedAt = endedAt
    rawText = ""
    editedText = ""
    formattedText = ""
    style = .natural
    spokenEdits = VoiceSpokenEditResult(
      sourceText: "",
      editedText: "",
      operations: []
    )
    formattedDocument = VoiceFormattedDocument(
      rawText: "",
      style: .natural,
      blocks: [],
      evidence: [],
      validationStatus: .sourceFallback
    )
    timedSegments = []
    modelPackageID = ""
    modelVersion = ""
    self.audioArtifact = audioArtifact
    audioExpiredAt = nil
    audioExpiredReason = nil
    recoveryReason = reason
  }

  private init(
    expiring session: VoiceInputHistorySession,
    at date: Date,
    reason: VoiceHistoryAudioExpirationReason
  ) {
    schemaRevision = session.schemaRevision
    id = session.id
    startedAt = session.startedAt
    endedAt = session.endedAt
    rawText = session.rawText
    editedText = session.editedText
    formattedText = session.formattedText
    style = session.style
    spokenEdits = session.spokenEdits
    formattedDocument = session.formattedDocument
    timedSegments = session.timedSegments
    modelPackageID = session.modelPackageID
    modelVersion = session.modelVersion
    audioArtifact = nil
    audioExpiredAt = date
    audioExpiredReason = reason
    recoveryReason = session.recoveryReason
  }

  func expiringAudio(
    at date: Date,
    reason: VoiceHistoryAudioExpirationReason
  ) -> Self {
    Self(expiring: self, at: date, reason: reason)
  }

  func validated(audioDirectoryURL: URL) throws -> Self {
    guard
      schemaRevision == Self.currentSchemaRevision,
      startedAt <= endedAt
    else {
      throw VoiceInputHistoryError.invalidSession
    }

    if recoveryReason == nil {
      guard
        !rawText.isEmpty,
        !editedText.isEmpty,
        !formattedText.isEmpty,
        !modelPackageID.isEmpty,
        !modelVersion.isEmpty
      else {
        throw VoiceInputHistoryError.invalidSession
      }
    } else {
      guard
        rawText.isEmpty,
        editedText.isEmpty,
        formattedText.isEmpty,
        modelPackageID.isEmpty,
        modelVersion.isEmpty,
        timedSegments.isEmpty,
        spokenEdits.sourceText.isEmpty,
        spokenEdits.editedText.isEmpty,
        spokenEdits.operations.isEmpty,
        formattedDocument.rawText.isEmpty,
        formattedDocument.blocks.isEmpty,
        formattedDocument.evidence.isEmpty
      else {
        throw VoiceInputHistoryError.invalidSession
      }
    }

    if let audioArtifact {
      let expectedURL =
        audioDirectoryURL
        .appendingPathComponent("\(id.uuidString.lowercased()).caf")
        .standardizedFileURL

      guard
        audioArtifact.url.standardizedFileURL == expectedURL,
        audioArtifact.byteCount > 0,
        audioArtifact.sha256.utf8.count == 64,
        audioArtifact.sha256.utf8.allSatisfy(Self.isLowercaseHexDigit),
        audioExpiredAt == nil,
        audioExpiredReason == nil
      else {
        throw VoiceInputHistoryError.invalidSession
      }
    } else {
      guard audioExpiredAt != nil, audioExpiredReason != nil else {
        throw VoiceInputHistoryError.invalidSession
      }
    }
    return self
  }

  var recoveryExpiresAt: Date? {
    recoveryReason.map { _ in
      endedAt.addingTimeInterval(Self.recoveryLifetime)
    }
  }

  var isRecovery: Bool {
    recoveryReason != nil
  }

  var recoveryDescription: String? {
    guard let recoveryReason else {
      return nil
    }
    switch recoveryReason {
    case .audioInterruption:
      return "An audio interruption stopped capture before transcription."
    case .audioRouteChange:
      return "An audio route change stopped capture before transcription."
    case .mediaServicesUnavailable:
      return "iOS audio services stopped capture before transcription."
    case .backgroundOwnershipUnavailable:
      return "Background capture stopped because its Live Activity was unavailable."
    case .backgroundExecutionExpired:
      return "iOS ended background finalization before transcription completed."
    case .thermalPressure:
      return "Critical thermal pressure stopped capture before transcription."
    case .processTermination:
      return "The app ended before this recording could be transcribed."
    case .finalizationFailure:
      return "Local transcription or History finalization did not complete."
    }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaRevision
    case id
    case startedAt
    case endedAt
    case rawText
    case editedText
    case formattedText
    case style
    case spokenEdits
    case formattedDocument
    case timedSegments
    case modelPackageID
    case modelVersion
    case audioArtifact
    case audioExpiredAt
    case audioExpiredReason
    case recoveryReason
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedRevision = try container.decode(Int.self, forKey: .schemaRevision)
    guard (1...Self.currentSchemaRevision).contains(decodedRevision) else {
      throw VoiceInputHistoryError.invalidSession
    }
    schemaRevision = Self.currentSchemaRevision
    id = try container.decode(UUID.self, forKey: .id)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    endedAt = try container.decode(Date.self, forKey: .endedAt)
    rawText = try container.decode(String.self, forKey: .rawText)
    editedText = try container.decode(String.self, forKey: .editedText)
    formattedText = try container.decode(String.self, forKey: .formattedText)
    style = try container.decode(VoiceStyle.self, forKey: .style)
    spokenEdits = try container.decode(VoiceSpokenEditResult.self, forKey: .spokenEdits)
    formattedDocument = try container.decode(
      VoiceFormattedDocument.self,
      forKey: .formattedDocument
    )
    timedSegments = try container.decode(
      [VoiceInputTranscriptSegment].self,
      forKey: .timedSegments
    )
    modelPackageID = try container.decode(String.self, forKey: .modelPackageID)
    modelVersion = try container.decode(String.self, forKey: .modelVersion)
    audioArtifact = try container.decodeIfPresent(
      VoiceInputHistoryAudioArtifact.self,
      forKey: .audioArtifact
    )
    audioExpiredAt = try container.decodeIfPresent(Date.self, forKey: .audioExpiredAt)
    audioExpiredReason = try container.decodeIfPresent(
      VoiceHistoryAudioExpirationReason.self,
      forKey: .audioExpiredReason
    )
    recoveryReason = try container.decodeIfPresent(
      VoiceInputCaptureInterruptionReason.self,
      forKey: .recoveryReason
    )
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.currentSchemaRevision, forKey: .schemaRevision)
    try container.encode(id, forKey: .id)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(endedAt, forKey: .endedAt)
    try container.encode(rawText, forKey: .rawText)
    try container.encode(editedText, forKey: .editedText)
    try container.encode(formattedText, forKey: .formattedText)
    try container.encode(style, forKey: .style)
    try container.encode(spokenEdits, forKey: .spokenEdits)
    try container.encode(formattedDocument, forKey: .formattedDocument)
    try container.encode(timedSegments, forKey: .timedSegments)
    try container.encode(modelPackageID, forKey: .modelPackageID)
    try container.encode(modelVersion, forKey: .modelVersion)
    try container.encodeIfPresent(audioArtifact, forKey: .audioArtifact)
    try container.encodeIfPresent(audioExpiredAt, forKey: .audioExpiredAt)
    try container.encodeIfPresent(audioExpiredReason, forKey: .audioExpiredReason)
    try container.encodeIfPresent(recoveryReason, forKey: .recoveryReason)
  }

  private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
  }
}
