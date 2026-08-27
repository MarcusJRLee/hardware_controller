use std::path::PathBuf;

use serde::Deserialize;

use crate::{
    AudioExpirationReason, RetentionCandidate, RetentionDecision, RetentionPlan, RetentionSettings,
    SessionId, plan_retention,
};

#[derive(Deserialize)]
struct Fixture {
    revision: u32,
    cases: Vec<FixtureCase>,
}

#[derive(Deserialize)]
struct FixtureCase {
    name: String,
    now_unix_milliseconds: i64,
    settings: FixtureSettings,
    low_disk_reclaim_bytes: i64,
    candidates: Vec<FixtureCandidate>,
    expected: FixturePlan,
}

#[derive(Deserialize)]
#[allow(
    clippy::struct_field_names,
    reason = "Fixture fields intentionally mirror the shared schema."
)]
struct FixtureSettings {
    maximum_age_days: Option<u32>,
    maximum_audio_bytes: Option<i64>,
    maximum_artifact_count: Option<u32>,
}

#[derive(Deserialize)]
struct FixtureCandidate {
    id: String,
    ended_at_unix_milliseconds: i64,
    audio_bytes: i64,
    is_pinned: bool,
    is_active: bool,
    is_sole_recovery_artifact: bool,
    recovery_expires_at_unix_milliseconds: Option<i64>,
}

#[derive(Deserialize)]
struct FixturePlan {
    decisions: Vec<FixtureDecision>,
    reclaimed_bytes: i64,
    low_disk_shortfall_bytes: i64,
    remaining_audio_bytes: i64,
    remaining_artifact_count: u32,
    exceeds_byte_limit: bool,
    exceeds_artifact_limit: bool,
}

#[derive(Deserialize)]
struct FixtureDecision {
    session_id: String,
    reason: FixtureReason,
    audio_bytes: i64,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum FixtureReason {
    AgeLimit,
    ArtifactLimit,
    ByteLimit,
    LowDisk,
    RecoveryLimit,
}

#[test]
fn shared_retention_fixture_matches_portable_policy() {
    let fixture_path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/cuj/voice_retention_v1.json");
    let fixture: Fixture = serde_json::from_slice(
        &std::fs::read(fixture_path).expect("The shared fixture must be readable."),
    )
    .expect("The shared fixture must match revision 1.");
    assert_eq!(fixture.revision, 1);

    for case in fixture.cases {
        let plan = plan_retention(
            &case
                .candidates
                .iter()
                .map(retention_candidate)
                .collect::<Vec<_>>(),
            RetentionSettings {
                maximum_age_days: case.settings.maximum_age_days,
                maximum_audio_bytes: case.settings.maximum_audio_bytes,
                maximum_artifact_count: case.settings.maximum_artifact_count,
            },
            case.now_unix_milliseconds,
            case.low_disk_reclaim_bytes,
        )
        .unwrap_or_else(|error| panic!("{} failed: {error:?}", case.name));

        assert_eq!(plan, retention_plan(case.expected), "{}", case.name);
    }
}

fn retention_candidate(candidate: &FixtureCandidate) -> RetentionCandidate {
    RetentionCandidate {
        session_id: session_id(&candidate.id),
        ended_at_unix_milliseconds: candidate.ended_at_unix_milliseconds,
        audio_bytes: candidate.audio_bytes,
        is_pinned: candidate.is_pinned,
        is_active: candidate.is_active,
        is_sole_recovery_artifact: candidate.is_sole_recovery_artifact,
        recovery_expires_at_unix_milliseconds: candidate.recovery_expires_at_unix_milliseconds,
    }
}

fn retention_plan(plan: FixturePlan) -> RetentionPlan {
    RetentionPlan {
        decisions: plan
            .decisions
            .into_iter()
            .map(|decision| RetentionDecision {
                session_id: session_id(&decision.session_id),
                reason: match decision.reason {
                    FixtureReason::AgeLimit => AudioExpirationReason::AgeLimit,
                    FixtureReason::ArtifactLimit => AudioExpirationReason::ArtifactLimit,
                    FixtureReason::ByteLimit => AudioExpirationReason::ByteLimit,
                    FixtureReason::LowDisk => AudioExpirationReason::LowDisk,
                    FixtureReason::RecoveryLimit => AudioExpirationReason::RecoveryLimit,
                },
                audio_bytes: decision.audio_bytes,
            })
            .collect(),
        reclaimed_bytes: plan.reclaimed_bytes,
        low_disk_shortfall_bytes: plan.low_disk_shortfall_bytes,
        remaining_audio_bytes: plan.remaining_audio_bytes,
        remaining_artifact_count: plan.remaining_artifact_count,
        exceeds_byte_limit: plan.exceeds_byte_limit,
        exceeds_artifact_limit: plan.exceeds_artifact_limit,
    }
}

fn session_id(value: &str) -> SessionId {
    value
        .parse()
        .expect("Fixture session IDs must be canonical.")
}

#[test]
fn invalid_boundaries_are_typed() {
    let candidate = RetentionCandidate {
        session_id: SessionId::from_bytes([1; 16]),
        ended_at_unix_milliseconds: 0,
        audio_bytes: 1,
        is_pinned: false,
        is_active: false,
        is_sole_recovery_artifact: false,
        recovery_expires_at_unix_milliseconds: None,
    };
    let unlimited = RetentionSettings {
        maximum_age_days: None,
        maximum_audio_bytes: None,
        maximum_artifact_count: None,
    };

    assert_eq!(
        plan_retention(&[candidate], unlimited, 0, -1),
        Err(crate::RetentionError::InvalidReclaimRequest)
    );
    assert_eq!(
        plan_retention(
            &[RetentionCandidate {
                audio_bytes: -1,
                ..candidate
            }],
            unlimited,
            0,
            0
        ),
        Err(crate::RetentionError::InvalidArtifactSize)
    );
    assert_eq!(
        plan_retention(&[candidate, candidate], unlimited, 0, 0),
        Err(crate::RetentionError::DuplicateSessionId)
    );
    assert_eq!(
        plan_retention(
            &[candidate],
            RetentionSettings {
                maximum_age_days: Some(RetentionSettings::MAXIMUM_AGE_DAYS + 1),
                ..unlimited
            },
            0,
            0
        ),
        Err(crate::RetentionError::InvalidAgeLimit)
    );
    assert_eq!(
        plan_retention(
            &[candidate],
            RetentionSettings {
                maximum_audio_bytes: Some(-1),
                ..unlimited
            },
            0,
            0
        ),
        Err(crate::RetentionError::InvalidByteLimit)
    );
    assert_eq!(
        plan_retention(
            &[candidate],
            RetentionSettings {
                maximum_artifact_count: Some(RetentionSettings::MAXIMUM_ARTIFACT_COUNT + 1,),
                ..unlimited
            },
            0,
            0
        ),
        Err(crate::RetentionError::InvalidArtifactLimit)
    );
    assert_eq!(
        plan_retention(
            &[
                RetentionCandidate {
                    audio_bytes: i64::MAX,
                    ..candidate
                },
                RetentionCandidate {
                    session_id: SessionId::from_bytes([2; 16]),
                    ..candidate
                },
            ],
            unlimited,
            0,
            0
        ),
        Err(crate::RetentionError::InvalidArtifactSize)
    );
    assert_eq!(
        plan_retention(
            &[candidate],
            RetentionSettings {
                maximum_age_days: Some(1),
                ..unlimited
            },
            i64::MIN,
            0
        ),
        Err(crate::RetentionError::InvalidTimestamp)
    );
}

#[test]
fn session_identifier_has_one_canonical_wire_form() {
    let lowercase = "12345678-9abc-def0-1234-56789abcdef0";
    let identifier = session_id("12345678-9ABC-DEF0-1234-56789ABCDEF0");

    assert_eq!(identifier.to_string(), lowercase);
    assert_eq!(SessionId::from_bytes(identifier.into_bytes()), identifier);
    assert_eq!(
        "not-a-session".parse::<SessionId>(),
        Err(crate::RetentionError::InvalidSessionId)
    );
}

#[test]
fn zero_age_selects_current_eligible_audio() {
    let candidate = RetentionCandidate {
        session_id: SessionId::from_bytes([1; 16]),
        ended_at_unix_milliseconds: 2_000,
        audio_bytes: 10,
        is_pinned: false,
        is_active: false,
        is_sole_recovery_artifact: false,
        recovery_expires_at_unix_milliseconds: None,
    };

    let plan = plan_retention(
        &[candidate],
        RetentionSettings {
            maximum_age_days: Some(0),
            maximum_audio_bytes: None,
            maximum_artifact_count: None,
        },
        2_000,
        0,
    )
    .expect("Zero age is a valid policy.");

    assert_eq!(
        plan.decisions,
        [RetentionDecision {
            session_id: candidate.session_id,
            reason: AudioExpirationReason::AgeLimit,
            audio_bytes: 10,
        }]
    );
}

#[test]
fn quota_reclamation_also_satisfies_low_disk() {
    let candidates = [1_u8, 2, 3].map(|value| RetentionCandidate {
        session_id: SessionId::from_bytes([value; 16]),
        ended_at_unix_milliseconds: i64::from(value),
        audio_bytes: 10,
        is_pinned: false,
        is_active: false,
        is_sole_recovery_artifact: false,
        recovery_expires_at_unix_milliseconds: None,
    });

    let plan = plan_retention(
        &candidates,
        RetentionSettings {
            maximum_age_days: None,
            maximum_audio_bytes: None,
            maximum_artifact_count: Some(2),
        },
        4,
        10,
    )
    .expect("Valid quota and disk policy must plan.");

    assert_eq!(plan.decisions.len(), 1);
    assert_eq!(
        plan.decisions[0].reason,
        AudioExpirationReason::ArtifactLimit
    );
    assert_eq!(plan.low_disk_shortfall_bytes, 0);
}
