use std::{collections::BTreeSet, fmt, str::FromStr};

const MILLISECONDS_PER_DAY: i64 = 86_400_000;

/// Stable, platform-neutral representation of a Voice session UUID.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct SessionId([u8; 16]);

impl SessionId {
    /// Builds an identifier from UUID bytes in network order.
    #[must_use]
    pub const fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(bytes)
    }

    /// Returns UUID bytes in network order.
    #[must_use]
    pub const fn into_bytes(self) -> [u8; 16] {
        self.0
    }
}

impl FromStr for SessionId {
    type Err = RetentionError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let bytes = value.as_bytes();
        if bytes.len() != 36
            || bytes[8] != b'-'
            || bytes[13] != b'-'
            || bytes[18] != b'-'
            || bytes[23] != b'-'
        {
            return Err(RetentionError::InvalidSessionId);
        }

        let mut result = [0_u8; 16];
        let mut source = 0;
        for target in &mut result {
            while matches!(source, 8 | 13 | 18 | 23) {
                source += 1;
            }
            let high = decode_hex(bytes[source])?;
            let low = decode_hex(bytes[source + 1])?;
            *target = (high << 4) | low;
            source += 2;
        }
        Ok(Self(result))
    }
}

impl fmt::Display for SessionId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (index, byte) in self.0.iter().enumerate() {
            if matches!(index, 4 | 6 | 8 | 10) {
                formatter.write_str("-")?;
            }
            write!(formatter, "{byte:02x}")?;
        }
        Ok(())
    }
}

/// Configurable audio-retention limits. `None` means unlimited and zero means
/// no retained audio for that dimension.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetentionSettings {
    /// Maximum completed-session age in days.
    pub maximum_age_days: Option<u32>,
    /// Maximum retained audio bytes.
    pub maximum_audio_bytes: Option<i64>,
    /// Maximum retained audio artifact count.
    pub maximum_artifact_count: Option<u32>,
}

impl RetentionSettings {
    /// Largest accepted age limit.
    pub const MAXIMUM_AGE_DAYS: u32 = 36_500;
    /// Largest accepted byte limit.
    pub const MAXIMUM_AUDIO_BYTES: i64 = 10 * 1_024 * 1_024 * 1_024 * 1_024;
    /// Largest accepted artifact limit.
    pub const MAXIMUM_ARTIFACT_COUNT: u32 = 1_000_000;

    fn validate(self) -> Result<Self, RetentionError> {
        if self
            .maximum_age_days
            .is_some_and(|value| value > Self::MAXIMUM_AGE_DAYS)
        {
            return Err(RetentionError::InvalidAgeLimit);
        }
        if self
            .maximum_audio_bytes
            .is_some_and(|value| !(0..=Self::MAXIMUM_AUDIO_BYTES).contains(&value))
        {
            return Err(RetentionError::InvalidByteLimit);
        }
        if self
            .maximum_artifact_count
            .is_some_and(|value| value > Self::MAXIMUM_ARTIFACT_COUNT)
        {
            return Err(RetentionError::InvalidArtifactLimit);
        }
        Ok(self)
    }
}

/// Immutable retained-audio evidence considered by the policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetentionCandidate {
    /// Owning Voice session.
    pub session_id: SessionId,
    /// Session completion time as Unix epoch milliseconds.
    pub ended_at_unix_milliseconds: i64,
    /// Artifact size in bytes.
    pub audio_bytes: i64,
    /// Whether the user pinned the session.
    pub is_pinned: bool,
    /// Whether capture still owns the artifact.
    pub is_active: bool,
    /// Whether this is the only recovery path for undelivered content.
    pub is_sole_recovery_artifact: bool,
    /// Dedicated recovery deadline as Unix epoch milliseconds.
    pub recovery_expires_at_unix_milliseconds: Option<i64>,
}

/// Durable reason for removing a retained audio artifact.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AudioExpirationReason {
    /// The configured age window elapsed.
    AgeLimit,
    /// The configured artifact-count limit was exceeded.
    ArtifactLimit,
    /// The configured byte limit was exceeded.
    ByteLimit,
    /// The platform requested emergency disk reclamation.
    LowDisk,
    /// The dedicated recovery window elapsed.
    RecoveryLimit,
}

/// One deterministic retention decision.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetentionDecision {
    /// Session whose audio should be removed.
    pub session_id: SessionId,
    /// Policy rule that selected the artifact.
    pub reason: AudioExpirationReason,
    /// Expected reclaimed bytes.
    pub audio_bytes: i64,
}

/// Complete deterministic output of a retention-policy evaluation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RetentionPlan {
    /// Ordered decisions, oldest artifact then session identifier.
    pub decisions: Vec<RetentionDecision>,
    /// Total bytes selected by all rules.
    pub reclaimed_bytes: i64,
    /// Requested low-disk bytes that protected artifacts prevented reclaiming.
    pub low_disk_shortfall_bytes: i64,
    /// Bytes remaining after every decision succeeds.
    pub remaining_audio_bytes: i64,
    /// Artifacts remaining after every decision succeeds.
    pub remaining_artifact_count: u32,
    /// Whether protected artifacts leave the byte cap unsatisfied.
    pub exceeds_byte_limit: bool,
    /// Whether protected artifacts leave the count cap unsatisfied.
    pub exceeds_artifact_limit: bool,
}

/// Typed validation failures at the portable policy boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetentionError {
    /// Age limit exceeds the supported range.
    InvalidAgeLimit,
    /// Artifact-count limit exceeds the supported range.
    InvalidArtifactLimit,
    /// Byte limit is negative or exceeds the supported range.
    InvalidByteLimit,
    /// Requested low-disk reclamation is negative.
    InvalidReclaimRequest,
    /// An artifact size is negative or the total overflows.
    InvalidArtifactSize,
    /// A session identifier is malformed.
    InvalidSessionId,
    /// Candidate identifiers are not unique.
    DuplicateSessionId,
    /// Age arithmetic exceeds the timestamp representation.
    InvalidTimestamp,
    /// The candidate or decision count exceeds the portable representation.
    TooManyCandidates,
}

/// Selects the oldest eligible artifacts deterministically for every limit.
///
/// # Errors
///
/// Returns a typed validation error for unsupported settings, malformed
/// candidates, overflow, duplicate identifiers, or a negative disk request.
#[allow(
    clippy::too_many_lines,
    reason = "Retention phases stay together to preserve their canonical precedence."
)]
pub fn plan_retention(
    candidates: &[RetentionCandidate],
    settings: RetentionSettings,
    now_unix_milliseconds: i64,
    low_disk_reclaim_bytes: i64,
) -> Result<RetentionPlan, RetentionError> {
    let settings = settings.validate()?;
    if low_disk_reclaim_bytes < 0 {
        return Err(RetentionError::InvalidReclaimRequest);
    }
    let candidate_count =
        u32::try_from(candidates.len()).map_err(|_| RetentionError::TooManyCandidates)?;
    let mut initial_bytes = 0_i64;
    let mut identifiers = BTreeSet::new();
    for candidate in candidates {
        if candidate.audio_bytes < 0 {
            return Err(RetentionError::InvalidArtifactSize);
        }
        initial_bytes = initial_bytes
            .checked_add(candidate.audio_bytes)
            .ok_or(RetentionError::InvalidArtifactSize)?;
        if !identifiers.insert(candidate.session_id) {
            return Err(RetentionError::DuplicateSessionId);
        }
    }

    let mut sorted = candidates.iter().collect::<Vec<_>>();
    sorted.sort_unstable_by_key(|candidate| {
        (candidate.ended_at_unix_milliseconds, candidate.session_id)
    });
    let mut selected = BTreeSet::new();
    let mut decisions = Vec::new();
    let mut reclaimed_bytes = 0_i64;

    for candidate in &sorted {
        if candidate
            .recovery_expires_at_unix_milliseconds
            .is_some_and(|deadline| deadline <= now_unix_milliseconds)
            && !candidate.is_pinned
            && !candidate.is_active
        {
            select(
                candidate,
                AudioExpirationReason::RecoveryLimit,
                &mut selected,
                &mut decisions,
                &mut reclaimed_bytes,
            );
        }
    }

    if let Some(maximum_age_days) = settings.maximum_age_days {
        let age_milliseconds = i64::from(maximum_age_days) * MILLISECONDS_PER_DAY;
        let cutoff = now_unix_milliseconds
            .checked_sub(age_milliseconds)
            .ok_or(RetentionError::InvalidTimestamp)?;
        for candidate in &sorted {
            if (maximum_age_days == 0 || candidate.ended_at_unix_milliseconds < cutoff)
                && is_eligible(candidate, &selected)
            {
                select(
                    candidate,
                    AudioExpirationReason::AgeLimit,
                    &mut selected,
                    &mut decisions,
                    &mut reclaimed_bytes,
                );
            }
        }
    }

    if let Some(maximum_artifact_count) = settings.maximum_artifact_count {
        let mut remaining_count = candidate_count
            - u32::try_from(selected.len()).map_err(|_| RetentionError::TooManyCandidates)?;
        for candidate in &sorted {
            if remaining_count > maximum_artifact_count && is_eligible(candidate, &selected) {
                select(
                    candidate,
                    AudioExpirationReason::ArtifactLimit,
                    &mut selected,
                    &mut decisions,
                    &mut reclaimed_bytes,
                );
                remaining_count -= 1;
            }
        }
    }

    if let Some(maximum_audio_bytes) = settings.maximum_audio_bytes {
        let mut remaining_bytes = initial_bytes - reclaimed_bytes;
        if remaining_bytes > maximum_audio_bytes {
            let low_water_bytes = maximum_audio_bytes * 90 / 100;
            for candidate in &sorted {
                if remaining_bytes > low_water_bytes && is_eligible(candidate, &selected) {
                    select(
                        candidate,
                        AudioExpirationReason::ByteLimit,
                        &mut selected,
                        &mut decisions,
                        &mut reclaimed_bytes,
                    );
                    remaining_bytes -= candidate.audio_bytes;
                }
            }
        }
    }

    if low_disk_reclaim_bytes > 0 {
        for candidate in &sorted {
            if reclaimed_bytes < low_disk_reclaim_bytes && is_eligible(candidate, &selected) {
                select(
                    candidate,
                    AudioExpirationReason::LowDisk,
                    &mut selected,
                    &mut decisions,
                    &mut reclaimed_bytes,
                );
            }
        }
    }

    let remaining_audio_bytes = initial_bytes - reclaimed_bytes;
    let remaining_artifact_count = candidate_count
        - u32::try_from(decisions.len()).map_err(|_| RetentionError::TooManyCandidates)?;
    Ok(RetentionPlan {
        decisions,
        reclaimed_bytes,
        low_disk_shortfall_bytes: (low_disk_reclaim_bytes - reclaimed_bytes).max(0),
        remaining_audio_bytes,
        remaining_artifact_count,
        exceeds_byte_limit: settings
            .maximum_audio_bytes
            .is_some_and(|limit| remaining_audio_bytes > limit),
        exceeds_artifact_limit: settings
            .maximum_artifact_count
            .is_some_and(|limit| remaining_artifact_count > limit),
    })
}

fn is_eligible(candidate: &RetentionCandidate, selected: &BTreeSet<SessionId>) -> bool {
    !selected.contains(&candidate.session_id)
        && !candidate.is_pinned
        && !candidate.is_active
        && !candidate.is_sole_recovery_artifact
}

fn select(
    candidate: &RetentionCandidate,
    reason: AudioExpirationReason,
    selected: &mut BTreeSet<SessionId>,
    decisions: &mut Vec<RetentionDecision>,
    reclaimed_bytes: &mut i64,
) {
    if selected.insert(candidate.session_id) {
        *reclaimed_bytes += candidate.audio_bytes;
        decisions.push(RetentionDecision {
            session_id: candidate.session_id,
            reason,
            audio_bytes: candidate.audio_bytes,
        });
    }
}

fn decode_hex(byte: u8) -> Result<u8, RetentionError> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => Err(RetentionError::InvalidSessionId),
    }
}
