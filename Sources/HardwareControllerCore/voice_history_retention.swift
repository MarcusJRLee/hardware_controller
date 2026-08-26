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

public enum VoiceHistoryRetentionPlanner {
  /// Selects oldest eligible artifacts deterministically for every limit.
  public static func plan(
    candidates: [VoiceHistoryRetentionCandidate],
    settings: VoiceHistoryRetentionSettings,
    now: Date,
    lowDiskReclaimBytes: Int64 = 0
  ) throws -> VoiceHistoryRetentionPlan {
    let settings = try settings.validated()
    guard lowDiskReclaimBytes >= 0 else {
      throw VoiceHistoryRetentionValidationError.invalidReclaimRequest
    }
    guard candidates.allSatisfy({ $0.audioBytes >= 0 }) else {
      throw VoiceHistoryRetentionValidationError.invalidArtifactSize
    }

    let sorted = candidates.sorted {
      if $0.endedAt != $1.endedAt {
        return $0.endedAt < $1.endedAt
      }
      return $0.id.uuidString < $1.id.uuidString
    }
    var initialBytes: Int64 = 0
    for candidate in candidates {
      let addition = initialBytes.addingReportingOverflow(
        candidate.audioBytes
      )
      guard !addition.overflow else {
        throw VoiceHistoryRetentionValidationError.invalidArtifactSize
      }
      initialBytes = addition.partialValue
    }
    var selected: Set<UUID> = []
    var decisions: [VoiceHistoryRetentionDecision] = []
    var reclaimedBytes: Int64 = 0

    func isEligible(_ candidate: VoiceHistoryRetentionCandidate) -> Bool {
      !selected.contains(candidate.id)
        && !candidate.isPinned
        && !candidate.isActive
        && !candidate.isSoleRecoveryArtifact
    }

    func select(
      _ candidate: VoiceHistoryRetentionCandidate,
      reason: VoiceHistoryAudioExpirationReason
    ) {
      selected.insert(candidate.id)
      reclaimedBytes += candidate.audioBytes
      decisions.append(
        VoiceHistoryRetentionDecision(
          sessionID: candidate.id,
          reason: reason,
          audioBytes: candidate.audioBytes
        )
      )
    }

    for candidate in sorted
    where candidate.recoveryExpiresAt.map({ $0 <= now }) == true
      && !candidate.isPinned
      && !candidate.isActive
      && !selected.contains(candidate.id)
    {
      select(candidate, reason: .recoveryLimit)
    }

    if let maximumAgeDays = settings.maximumAgeDays {
      let cutoff = now.addingTimeInterval(
        -TimeInterval(maximumAgeDays) * 86_400
      )
      for candidate in sorted
      where (maximumAgeDays == 0 || candidate.endedAt < cutoff)
        && isEligible(candidate)
      {
        select(candidate, reason: .ageLimit)
      }
    }

    if let maximumArtifactCount = settings.maximumArtifactCount {
      var remainingCount = candidates.count - selected.count
      for candidate in sorted
      where remainingCount > maximumArtifactCount && isEligible(candidate) {
        select(candidate, reason: .artifactLimit)
        remainingCount -= 1
      }
    }

    if let maximumAudioBytes = settings.maximumAudioBytes {
      var remainingBytes = initialBytes - reclaimedBytes
      if remainingBytes > maximumAudioBytes {
        // Evicting to a low-water mark avoids expiring one artifact per session.
        let lowWaterBytes = maximumAudioBytes * 90 / 100
        for candidate in sorted
        where remainingBytes > lowWaterBytes && isEligible(candidate) {
          select(candidate, reason: .byteLimit)
          remainingBytes -= candidate.audioBytes
        }
      }
    }

    if lowDiskReclaimBytes > 0 {
      for candidate in sorted
      where reclaimedBytes < lowDiskReclaimBytes
        && isEligible(candidate)
      {
        select(candidate, reason: .lowDisk)
      }
      let shortfall = max(0, lowDiskReclaimBytes - reclaimedBytes)
      return result(
        candidates: candidates,
        settings: settings,
        decisions: decisions,
        reclaimedBytes: reclaimedBytes,
        lowDiskShortfallBytes: shortfall
      )
    }

    return result(
      candidates: candidates,
      settings: settings,
      decisions: decisions,
      reclaimedBytes: reclaimedBytes,
      lowDiskShortfallBytes: 0
    )
  }

  private static func result(
    candidates: [VoiceHistoryRetentionCandidate],
    settings: VoiceHistoryRetentionSettings,
    decisions: [VoiceHistoryRetentionDecision],
    reclaimedBytes: Int64,
    lowDiskShortfallBytes: Int64
  ) -> VoiceHistoryRetentionPlan {
    let remainingAudioBytes =
      candidates.reduce(Int64.zero) {
        $0 + $1.audioBytes
      } - reclaimedBytes
    let remainingArtifactCount = candidates.count - decisions.count
    return VoiceHistoryRetentionPlan(
      decisions: decisions,
      reclaimedBytes: reclaimedBytes,
      lowDiskShortfallBytes: lowDiskShortfallBytes,
      remainingAudioBytes: remainingAudioBytes,
      remainingArtifactCount: remainingArtifactCount,
      exceedsByteLimit: settings.maximumAudioBytes.map {
        remainingAudioBytes > $0
      } ?? false,
      exceedsArtifactLimit: settings.maximumArtifactCount.map {
        remainingArtifactCount > $0
      } ?? false
    )
  }
}
