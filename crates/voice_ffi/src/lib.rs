//! Versioned synchronous C ABI for the portable Voice engine.

use std::{panic::AssertUnwindSafe, slice};

use voice_core::{
    AudioExpirationReason, RetentionCandidate, RetentionError, RetentionSettings, SessionId,
    plan_retention,
};

/// The request completed successfully.
pub const VOICE_STATUS_OK: u32 = 0;
/// A required request, output, candidate, or decision pointer was null.
pub const VOICE_STATUS_NULL_POINTER: u32 = 1;
/// A value or reserved field violated the versioned contract.
pub const VOICE_STATUS_INVALID_ARGUMENT: u32 = 2;
/// The caller-owned decision buffer is too small.
pub const VOICE_STATUS_BUFFER_TOO_SMALL: u32 = 3;
/// An internal panic was contained at the ABI boundary.
pub const VOICE_STATUS_INTERNAL_FAILURE: u32 = 4;
/// The age limit exceeds the supported range.
pub const VOICE_STATUS_INVALID_AGE_LIMIT: u32 = 5;
/// The artifact-count limit exceeds the supported range.
pub const VOICE_STATUS_INVALID_ARTIFACT_LIMIT: u32 = 6;
/// The byte limit is negative or exceeds the supported range.
pub const VOICE_STATUS_INVALID_BYTE_LIMIT: u32 = 7;
/// The low-disk reclaim request is negative.
pub const VOICE_STATUS_INVALID_RECLAIM_REQUEST: u32 = 8;
/// An artifact size is negative or the total overflows.
pub const VOICE_STATUS_INVALID_ARTIFACT_SIZE: u32 = 9;
/// A session identifier is malformed.
pub const VOICE_STATUS_INVALID_SESSION_ID: u32 = 10;
/// Candidate identifiers are not unique.
pub const VOICE_STATUS_DUPLICATE_SESSION_ID: u32 = 11;
/// Age arithmetic exceeds the timestamp representation.
pub const VOICE_STATUS_INVALID_TIMESTAMP: u32 = 12;
/// Candidate or decision count exceeds the portable representation.
pub const VOICE_STATUS_TOO_MANY_CANDIDATES: u32 = 13;

/// Voice session UUID bytes in network order.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct VoiceSessionIdV1 {
    /// RFC 4122 UUID bytes.
    pub bytes: [u8; 16],
}

/// Versioned optional retention limits.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct VoiceRetentionSettingsV1 {
    /// Whether `maximum_age_days` is present.
    pub has_maximum_age_days: u8,
    /// Whether `maximum_audio_bytes` is present.
    pub has_maximum_audio_bytes: u8,
    /// Whether `maximum_artifact_count` is present.
    pub has_maximum_artifact_count: u8,
    /// Must be zero.
    pub reserved: u8,
    /// Maximum completed-session age in days.
    pub maximum_age_days: u32,
    /// Maximum retained artifact count.
    pub maximum_artifact_count: u32,
    /// Maximum retained audio bytes.
    pub maximum_audio_bytes: i64,
}

/// One immutable artifact considered by the portable retention policy.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct VoiceRetentionCandidateV1 {
    /// Owning Voice session.
    pub session_id: VoiceSessionIdV1,
    /// Session completion time as Unix epoch milliseconds.
    pub ended_at_unix_milliseconds: i64,
    /// Artifact size in bytes.
    pub audio_bytes: i64,
    /// Dedicated recovery deadline as Unix epoch milliseconds.
    pub recovery_expires_at_unix_milliseconds: i64,
    /// Whether the user pinned the session.
    pub is_pinned: u8,
    /// Whether capture still owns the artifact.
    pub is_active: u8,
    /// Whether the artifact is the only recovery path.
    pub is_sole_recovery_artifact: u8,
    /// Whether `recovery_expires_at_unix_milliseconds` is present.
    pub has_recovery_expires_at: u8,
    /// Must contain only zeroes.
    pub reserved: [u8; 4],
}

/// Versioned retention request. The caller owns the candidate memory.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct VoiceRetentionRequestV1 {
    /// Retention limits.
    pub settings: VoiceRetentionSettingsV1,
    /// Evaluation time as Unix epoch milliseconds.
    pub now_unix_milliseconds: i64,
    /// Additional low-disk bytes requested by the platform.
    pub low_disk_reclaim_bytes: i64,
    /// Candidate array, or null only when `candidate_count` is zero.
    pub candidates: *const VoiceRetentionCandidateV1,
    /// Number of readable candidate elements.
    pub candidate_count: usize,
}

/// One ordered portable retention decision.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct VoiceRetentionDecisionV1 {
    /// Owning Voice session.
    pub session_id: VoiceSessionIdV1,
    /// Stable reason code: age 1, artifact 2, bytes 3, disk 4, recovery 5.
    pub reason: u32,
    /// Must be zero and is written as zero.
    pub reserved: u32,
    /// Expected reclaimed bytes.
    pub audio_bytes: i64,
}

/// Versioned retention output. The caller allocates and owns `decisions`.
#[repr(C)]
#[derive(Debug)]
pub struct VoiceRetentionPlanV1 {
    /// Writable decision array, or null only when `decision_capacity` is zero.
    pub decisions: *mut VoiceRetentionDecisionV1,
    /// Number of writable decision elements.
    pub decision_capacity: usize,
    /// Required decision count, including on `VOICE_STATUS_BUFFER_TOO_SMALL`.
    pub decision_count: usize,
    /// Total bytes selected by all rules.
    pub reclaimed_bytes: i64,
    /// Requested bytes that protected artifacts prevented reclaiming.
    pub low_disk_shortfall_bytes: i64,
    /// Bytes remaining after every decision succeeds.
    pub remaining_audio_bytes: i64,
    /// Artifacts remaining after every decision succeeds.
    pub remaining_artifact_count: u32,
    /// Whether protected artifacts leave the byte cap unsatisfied.
    pub exceeds_byte_limit: u8,
    /// Whether protected artifacts leave the count cap unsatisfied.
    pub exceeds_artifact_limit: u8,
    /// Written as zeroes.
    pub reserved: [u8; 2],
}

/// Evaluates retention without retaining caller pointers after return.
///
/// The caller must provide valid, aligned pointers for their declared lengths.
/// Call once with zero decision capacity to learn the required count, allocate,
/// then call again. No callback, allocator, thread, or runtime handle crosses
/// this boundary.
///
/// # Safety
///
/// Every non-null pointer must be aligned and valid for the declared readable
/// or writable element count for the duration of this call. Input and output
/// request, output structure, and their declared arrays must not overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn voice_retention_plan_v1(
    request: *const VoiceRetentionRequestV1,
    output: *mut VoiceRetentionPlanV1,
) -> u32 {
    std::panic::catch_unwind(AssertUnwindSafe(|| {
        // Safety: Pointer validity and alignment are the documented C precondition.
        unsafe { plan(request, output) }
    }))
    .unwrap_or(VOICE_STATUS_INTERNAL_FAILURE)
}

unsafe fn plan(request: *const VoiceRetentionRequestV1, output: *mut VoiceRetentionPlanV1) -> u32 {
    if request.is_null() || output.is_null() {
        return VOICE_STATUS_NULL_POINTER;
    }
    // Safety: Null pointers were rejected and validity is the caller contract.
    let request = unsafe { &*request };
    // Safety: Null pointers were rejected and exclusive output is the caller contract.
    let output = unsafe { &mut *output };
    output.decision_count = 0;
    output.reclaimed_bytes = 0;
    output.low_disk_shortfall_bytes = 0;
    output.remaining_audio_bytes = 0;
    output.remaining_artifact_count = 0;
    output.exceeds_byte_limit = 0;
    output.exceeds_artifact_limit = 0;
    output.reserved = [0; 2];

    if output.decision_capacity > 0 && output.decisions.is_null() {
        return VOICE_STATUS_NULL_POINTER;
    }
    if request.candidate_count > 0 && request.candidates.is_null() {
        return VOICE_STATUS_NULL_POINTER;
    }
    let raw_candidates = if request.candidate_count == 0 {
        &[]
    } else {
        // Safety: The caller promises this many readable, aligned elements.
        unsafe { slice::from_raw_parts(request.candidates, request.candidate_count) }
    };
    let Ok(settings) = settings(request.settings) else {
        return VOICE_STATUS_INVALID_ARGUMENT;
    };
    let mut candidates = Vec::with_capacity(raw_candidates.len());
    for raw_candidate in raw_candidates {
        let Ok(candidate) = decode_candidate(*raw_candidate) else {
            return VOICE_STATUS_INVALID_ARGUMENT;
        };
        candidates.push(candidate);
    }
    let plan = match plan_retention(
        &candidates,
        settings,
        request.now_unix_milliseconds,
        request.low_disk_reclaim_bytes,
    ) {
        Ok(value) => value,
        Err(error) => return status(error),
    };

    output.decision_count = plan.decisions.len();
    output.reclaimed_bytes = plan.reclaimed_bytes;
    output.low_disk_shortfall_bytes = plan.low_disk_shortfall_bytes;
    output.remaining_audio_bytes = plan.remaining_audio_bytes;
    output.remaining_artifact_count = plan.remaining_artifact_count;
    output.exceeds_byte_limit = u8::from(plan.exceeds_byte_limit);
    output.exceeds_artifact_limit = u8::from(plan.exceeds_artifact_limit);
    if plan.decisions.len() > output.decision_capacity {
        return VOICE_STATUS_BUFFER_TOO_SMALL;
    }
    if !plan.decisions.is_empty() {
        // Safety: Capacity was checked and the caller promises writable elements.
        let destination =
            unsafe { slice::from_raw_parts_mut(output.decisions, plan.decisions.len()) };
        for (destination, decision) in destination.iter_mut().zip(plan.decisions) {
            *destination = VoiceRetentionDecisionV1 {
                session_id: VoiceSessionIdV1 {
                    bytes: decision.session_id.into_bytes(),
                },
                reason: reason(decision.reason),
                reserved: 0,
                audio_bytes: decision.audio_bytes,
            };
        }
    }
    VOICE_STATUS_OK
}

fn settings(value: VoiceRetentionSettingsV1) -> Result<RetentionSettings, ()> {
    if value.reserved != 0 {
        return Err(());
    }
    Ok(RetentionSettings {
        maximum_age_days: optional(value.has_maximum_age_days, value.maximum_age_days)?,
        maximum_audio_bytes: optional(value.has_maximum_audio_bytes, value.maximum_audio_bytes)?,
        maximum_artifact_count: optional(
            value.has_maximum_artifact_count,
            value.maximum_artifact_count,
        )?,
    })
}

fn decode_candidate(value: VoiceRetentionCandidateV1) -> Result<RetentionCandidate, ()> {
    if value.reserved != [0; 4] {
        return Err(());
    }
    Ok(RetentionCandidate {
        session_id: SessionId::from_bytes(value.session_id.bytes),
        ended_at_unix_milliseconds: value.ended_at_unix_milliseconds,
        audio_bytes: value.audio_bytes,
        is_pinned: boolean(value.is_pinned)?,
        is_active: boolean(value.is_active)?,
        is_sole_recovery_artifact: boolean(value.is_sole_recovery_artifact)?,
        recovery_expires_at_unix_milliseconds: optional(
            value.has_recovery_expires_at,
            value.recovery_expires_at_unix_milliseconds,
        )?,
    })
}

fn optional<T>(present: u8, value: T) -> Result<Option<T>, ()> {
    match present {
        0 => Ok(None),
        1 => Ok(Some(value)),
        _ => Err(()),
    }
}

fn boolean(value: u8) -> Result<bool, ()> {
    match value {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(()),
    }
}

const fn reason(value: AudioExpirationReason) -> u32 {
    match value {
        AudioExpirationReason::AgeLimit => 1,
        AudioExpirationReason::ArtifactLimit => 2,
        AudioExpirationReason::ByteLimit => 3,
        AudioExpirationReason::LowDisk => 4,
        AudioExpirationReason::RecoveryLimit => 5,
    }
}

const fn status(error: RetentionError) -> u32 {
    match error {
        RetentionError::InvalidAgeLimit => VOICE_STATUS_INVALID_AGE_LIMIT,
        RetentionError::InvalidArtifactLimit => VOICE_STATUS_INVALID_ARTIFACT_LIMIT,
        RetentionError::InvalidByteLimit => VOICE_STATUS_INVALID_BYTE_LIMIT,
        RetentionError::InvalidReclaimRequest => VOICE_STATUS_INVALID_RECLAIM_REQUEST,
        RetentionError::InvalidArtifactSize => VOICE_STATUS_INVALID_ARTIFACT_SIZE,
        RetentionError::InvalidSessionId => VOICE_STATUS_INVALID_SESSION_ID,
        RetentionError::DuplicateSessionId => VOICE_STATUS_DUPLICATE_SESSION_ID,
        RetentionError::InvalidTimestamp => VOICE_STATUS_INVALID_TIMESTAMP,
        RetentionError::TooManyCandidates => VOICE_STATUS_TOO_MANY_CANDIDATES,
    }
}

#[cfg(test)]
mod ffi_test;
