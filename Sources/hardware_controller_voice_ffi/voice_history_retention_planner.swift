import Foundation
import HardwareControllerCore
import VoiceFFIBridge

/// Plans History audio expiry with the portable Rust policy, so macOS, iOS,
/// and later platforms share one implementation instead of conformant copies.
public struct RustVoiceHistoryRetentionPlanner: Sendable {
  public init() {}

  public func plan(
    candidates: [VoiceHistoryRetentionCandidate],
    settings: VoiceHistoryRetentionSettings,
    now: Date,
    lowDiskReclaimBytes: Int64 = 0
  ) throws -> VoiceHistoryRetentionPlan {
    let settings = try settings.validated()
    var request = VoiceRetentionRequestV1()
    request.settings = Self.settings(settings)
    request.now_unix_milliseconds = try Self.milliseconds(now)
    request.low_disk_reclaim_bytes = lowDiskReclaimBytes
    let rawCandidates = try candidates.map(Self.candidate)
    var decisions = [VoiceRetentionDecisionV1](
      repeating: VoiceRetentionDecisionV1(),
      count: max(candidates.count, 1)
    )
    var output = VoiceRetentionPlanV1()
    let status = rawCandidates.withUnsafeBufferPointer { candidateBuffer in
      decisions.withUnsafeMutableBufferPointer { decisionBuffer in
        request.candidates = candidateBuffer.baseAddress
        request.candidate_count = candidateBuffer.count
        output.decisions = decisionBuffer.baseAddress
        output.decision_capacity = decisionBuffer.count
        return voice_retention_plan_v1(&request, &output)
      }
    }
    guard status == VoiceFFIBridgeStatusOK.rawValue else {
      throw Self.error(for: status)
    }
    guard output.decision_count <= decisions.count else {
      throw VoiceHistoryRetentionValidationError.portablePolicyFailure
    }
    return VoiceHistoryRetentionPlan(
      decisions: try decisions.prefix(output.decision_count).map(Self.decision),
      reclaimedBytes: output.reclaimed_bytes,
      lowDiskShortfallBytes: output.low_disk_shortfall_bytes,
      remainingAudioBytes: output.remaining_audio_bytes,
      remainingArtifactCount: Int(output.remaining_artifact_count),
      exceedsByteLimit: try Self.flag(output.exceeds_byte_limit),
      exceedsArtifactLimit: try Self.flag(output.exceeds_artifact_limit)
    )
  }

  private static func settings(
    _ settings: VoiceHistoryRetentionSettings
  ) -> VoiceRetentionSettingsV1 {
    var raw = VoiceRetentionSettingsV1()
    if let maximumAgeDays = settings.maximumAgeDays {
      raw.has_maximum_age_days = 1
      raw.maximum_age_days = UInt32(maximumAgeDays)
    }
    if let maximumAudioBytes = settings.maximumAudioBytes {
      raw.has_maximum_audio_bytes = 1
      raw.maximum_audio_bytes = maximumAudioBytes
    }
    if let maximumArtifactCount = settings.maximumArtifactCount {
      raw.has_maximum_artifact_count = 1
      raw.maximum_artifact_count = UInt32(maximumArtifactCount)
    }
    return raw
  }

  private static func candidate(
    _ candidate: VoiceHistoryRetentionCandidate
  ) throws -> VoiceRetentionCandidateV1 {
    var raw = VoiceRetentionCandidateV1()
    raw.session_id = sessionID(candidate.id)
    raw.ended_at_unix_milliseconds = try milliseconds(candidate.endedAt)
    raw.audio_bytes = candidate.audioBytes
    raw.is_pinned = candidate.isPinned ? 1 : 0
    raw.is_active = candidate.isActive ? 1 : 0
    raw.is_sole_recovery_artifact = candidate.isSoleRecoveryArtifact ? 1 : 0
    if let recoveryExpiresAt = candidate.recoveryExpiresAt {
      raw.has_recovery_expires_at = 1
      raw.recovery_expires_at_unix_milliseconds = try milliseconds(recoveryExpiresAt)
    }
    return raw
  }

  private static func decision(
    _ raw: VoiceRetentionDecisionV1
  ) throws -> VoiceHistoryRetentionDecision {
    let reason: VoiceHistoryAudioExpirationReason
    switch raw.reason {
    case VoiceFFIBridgeExpirationAgeLimit.rawValue: reason = .ageLimit
    case VoiceFFIBridgeExpirationArtifactLimit.rawValue: reason = .artifactLimit
    case VoiceFFIBridgeExpirationByteLimit.rawValue: reason = .byteLimit
    case VoiceFFIBridgeExpirationLowDisk.rawValue: reason = .lowDisk
    case VoiceFFIBridgeExpirationRecoveryLimit.rawValue: reason = .recoveryLimit
    default: throw VoiceHistoryRetentionValidationError.portablePolicyFailure
    }
    return VoiceHistoryRetentionDecision(
      sessionID: UUID(uuid: raw.session_id.bytes),
      reason: reason,
      audioBytes: raw.audio_bytes
    )
  }

  /// UUID bytes are already in network order, matching the ABI contract.
  private static func sessionID(_ identifier: UUID) -> VoiceSessionIdV1 {
    VoiceSessionIdV1(bytes: identifier.uuid)
  }

  /// Truncates toward negative infinity so that ordering is preserved.
  private static func milliseconds(_ date: Date) throws -> Int64 {
    let value = (date.timeIntervalSince1970 * 1_000).rounded(.down)
    guard value.isFinite, let milliseconds = Int64(exactly: value) else {
      throw VoiceHistoryRetentionValidationError.invalidTimestamp
    }
    return milliseconds
  }

  private static func flag(_ value: UInt8) throws -> Bool {
    switch value {
    case 0: false
    case 1: true
    default: throw VoiceHistoryRetentionValidationError.portablePolicyFailure
    }
  }

  private static func error(for status: UInt32) -> VoiceHistoryRetentionValidationError {
    switch status {
    case VoiceFFIBridgeStatusInvalidAgeLimit.rawValue: .invalidAgeLimit
    case VoiceFFIBridgeStatusInvalidArtifactLimit.rawValue: .invalidArtifactLimit
    case VoiceFFIBridgeStatusInvalidByteLimit.rawValue: .invalidByteLimit
    case VoiceFFIBridgeStatusInvalidReclaimRequest.rawValue: .invalidReclaimRequest
    case VoiceFFIBridgeStatusInvalidArtifactSize.rawValue: .invalidArtifactSize
    case VoiceFFIBridgeStatusDuplicateSessionId.rawValue: .duplicateSession
    case VoiceFFIBridgeStatusInvalidTimestamp.rawValue: .invalidTimestamp
    case VoiceFFIBridgeStatusTooManyCandidates.rawValue: .tooManyArtifacts
    default: .portablePolicyFailure
    }
  }
}
