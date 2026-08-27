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
  static let currentSchemaRevision = 1

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
      startedAt <= endedAt,
      !rawText.isEmpty,
      !editedText.isEmpty,
      !formattedText.isEmpty,
      !modelPackageID.isEmpty,
      !modelVersion.isEmpty
    else {
      throw VoiceInputHistoryError.invalidSession
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

  private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
  }
}
