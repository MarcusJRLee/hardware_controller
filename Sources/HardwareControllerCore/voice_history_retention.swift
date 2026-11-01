import Foundation

public enum VoiceHistoryRetentionValidationError:
  Error,
  Equatable,
  Sendable
{
  case invalidAgeLimit
  case invalidArtifactLimit
  case invalidByteLimit
  case invalidReclaimRequest
  case invalidArtifactSize
  case duplicateSession
  case invalidTimestamp
  case tooManyArtifacts
  /// The portable planner returned a status or value outside its contract.
  case portablePolicyFailure
}

public struct VoiceHistoryRetentionSettings:
  Codable,
  Equatable,
  Sendable
{
  public static let maximumAgeDays = 36_500
  public static let maximumArtifactCount = 1_000_000
  public static let maximumAudioBytes: Int64 = 10 * 1_024 * 1_024 * 1_024 * 1_024

  public static let macOSDefault = VoiceHistoryRetentionSettings(
    maximumAgeDays: 90,
    maximumAudioBytes: 2 * 1_024 * 1_024 * 1_024,
    maximumArtifactCount: 5_000
  )
  public static let iOSDefault = VoiceHistoryRetentionSettings(
    maximumAgeDays: 90,
    maximumAudioBytes: 1 * 1_024 * 1_024 * 1_024,
    maximumArtifactCount: 2_000
  )
  public static let unlimited = VoiceHistoryRetentionSettings(
    maximumAgeDays: nil,
    maximumAudioBytes: nil,
    maximumArtifactCount: nil
  )

  /// Nil means Unlimited. Zero disables retained audio for completed sessions.
  public let maximumAgeDays: Int?
  /// Nil means Unlimited. Zero disables retained audio for completed sessions.
  public let maximumAudioBytes: Int64?
  /// Nil means Unlimited. Zero disables retained audio for completed sessions.
  public let maximumArtifactCount: Int?

  public init(
    maximumAgeDays: Int?,
    maximumAudioBytes: Int64?,
    maximumArtifactCount: Int?
  ) {
    self.maximumAgeDays = maximumAgeDays
    self.maximumAudioBytes = maximumAudioBytes
    self.maximumArtifactCount = maximumArtifactCount
  }

  public func validated() throws -> Self {
    if let maximumAgeDays,
      !(0...Self.maximumAgeDays).contains(maximumAgeDays)
    {
      throw VoiceHistoryRetentionValidationError.invalidAgeLimit
    }
    if let maximumAudioBytes,
      !(0...Self.maximumAudioBytes).contains(maximumAudioBytes)
    {
      throw VoiceHistoryRetentionValidationError.invalidByteLimit
    }
    if let maximumArtifactCount,
      !(0...Self.maximumArtifactCount).contains(maximumArtifactCount)
    {
      throw VoiceHistoryRetentionValidationError.invalidArtifactLimit
    }
    return self
  }
}

public enum VoiceHistoryAudioExpirationReason:
  String,
  Codable,
  Equatable,
  Sendable
{
  case ageLimit = "age_limit"
  case artifactLimit = "artifact_limit"
  case byteLimit = "byte_limit"
  case lowDisk = "low_disk"
  case recoveryLimit = "recovery_limit"
}

public struct VoiceHistoryRetentionCandidate:
  Equatable,
  Identifiable,
  Sendable
{
  public let id: UUID
  public let endedAt: Date
  public let audioBytes: Int64
  public let isPinned: Bool
  public let isActive: Bool
  public let isSoleRecoveryArtifact: Bool
  public let recoveryExpiresAt: Date?

  public init(
    id: UUID,
    endedAt: Date,
    audioBytes: Int64,
    isPinned: Bool,
    isActive: Bool,
    isSoleRecoveryArtifact: Bool,
    recoveryExpiresAt: Date? = nil
  ) {
    self.id = id
    self.endedAt = endedAt
    self.audioBytes = audioBytes
    self.isPinned = isPinned
    self.isActive = isActive
    self.isSoleRecoveryArtifact = isSoleRecoveryArtifact
    self.recoveryExpiresAt = recoveryExpiresAt
  }
}

public struct VoiceHistoryRetentionDecision:
  Equatable,
  Sendable
{
  public let sessionID: UUID
  public let reason: VoiceHistoryAudioExpirationReason
  public let audioBytes: Int64

  public init(
    sessionID: UUID,
    reason: VoiceHistoryAudioExpirationReason,
    audioBytes: Int64
  ) {
    self.sessionID = sessionID
    self.reason = reason
    self.audioBytes = audioBytes
  }
}

public struct VoiceHistoryRetentionPlan:
  Equatable,
  Sendable
{
  public let decisions: [VoiceHistoryRetentionDecision]
  public let reclaimedBytes: Int64
  public let lowDiskShortfallBytes: Int64
  public let remainingAudioBytes: Int64
  public let remainingArtifactCount: Int
  public let exceedsByteLimit: Bool
  public let exceedsArtifactLimit: Bool

  public init(
    decisions: [VoiceHistoryRetentionDecision],
    reclaimedBytes: Int64,
    lowDiskShortfallBytes: Int64,
    remainingAudioBytes: Int64,
    remainingArtifactCount: Int,
    exceedsByteLimit: Bool,
    exceedsArtifactLimit: Bool
  ) {
    self.decisions = decisions
    self.reclaimedBytes = reclaimedBytes
    self.lowDiskShortfallBytes = lowDiskShortfallBytes
    self.remainingAudioBytes = remainingAudioBytes
    self.remainingArtifactCount = remainingArtifactCount
    self.exceedsByteLimit = exceedsByteLimit
    self.exceedsArtifactLimit = exceedsArtifactLimit
  }
}
