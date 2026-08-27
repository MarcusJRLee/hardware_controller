use std::{mem::size_of, ptr};

use crate::{
    VOICE_STATUS_BUFFER_TOO_SMALL, VOICE_STATUS_INVALID_ARGUMENT,
    VOICE_STATUS_INVALID_RECLAIM_REQUEST, VOICE_STATUS_NULL_POINTER, VOICE_STATUS_OK,
    VoiceRetentionCandidateV1, VoiceRetentionDecisionV1, VoiceRetentionPlanV1,
    VoiceRetentionRequestV1, VoiceRetentionSettingsV1, VoiceSessionIdV1, voice_retention_plan_v1,
};

#[test]
fn caller_owned_buffer_negotiates_then_receives_one_decision() {
    let candidates = candidates();
    let request = make_request(&candidates);
    let mut output = make_output(&mut []);

    // Safety: Every pointer references live, aligned storage for the call.
    let status = unsafe { voice_retention_plan_v1(&raw const request, &raw mut output) };
    assert_eq!(status, VOICE_STATUS_BUFFER_TOO_SMALL);
    assert_eq!(output.decision_count, 1);

    let mut decisions = [empty_decision()];
    let mut output = make_output(&mut decisions);
    // Safety: Every pointer references live, aligned storage for the call.
    let status = unsafe { voice_retention_plan_v1(&raw const request, &raw mut output) };
    assert_eq!(status, VOICE_STATUS_OK);
    assert_eq!(output.decision_count, 1);
    assert_eq!(decisions[0].session_id.bytes, [1; 16]);
    assert_eq!(decisions[0].reason, 2);
    assert_eq!(decisions[0].audio_bytes, 10);
}

#[test]
fn invalid_boolean_is_rejected_without_writing_decisions() {
    let mut candidates = candidates();
    candidates[0].is_pinned = 2;
    let request = make_request(&candidates);
    let mut decisions = [empty_decision()];
    let mut output = make_output(&mut decisions);

    // Safety: Every pointer references live, aligned storage for the call.
    let status = unsafe { voice_retention_plan_v1(&raw const request, &raw mut output) };

    assert_eq!(status, VOICE_STATUS_INVALID_ARGUMENT);
    assert_eq!(output.decision_count, 0);
}

#[test]
fn domain_validation_error_remains_typed() {
    let candidates = candidates();
    let mut request = make_request(&candidates);
    request.low_disk_reclaim_bytes = -1;
    let mut output = make_output(&mut []);

    // Safety: Every pointer references live, aligned, nonoverlapping storage.
    let status = unsafe { voice_retention_plan_v1(&raw const request, &raw mut output) };

    assert_eq!(status, VOICE_STATUS_INVALID_RECLAIM_REQUEST);
}

#[test]
fn null_boundaries_fail_closed() {
    let candidates = candidates();
    let mut request = make_request(&candidates);
    let mut output = make_output(&mut []);

    // Safety: The function explicitly accepts null to report a typed error.
    assert_eq!(
        unsafe { voice_retention_plan_v1(ptr::null(), &raw mut output) },
        VOICE_STATUS_NULL_POINTER
    );
    // Safety: The function explicitly accepts null to report a typed error.
    assert_eq!(
        unsafe { voice_retention_plan_v1(&raw const request, ptr::null_mut()) },
        VOICE_STATUS_NULL_POINTER
    );

    request.candidates = ptr::null();
    // Safety: The request and output structures are live and nonoverlapping.
    assert_eq!(
        unsafe { voice_retention_plan_v1(&raw const request, &raw mut output) },
        VOICE_STATUS_NULL_POINTER
    );

    request = make_request(&candidates);
    output.decisions = ptr::null_mut();
    output.decision_capacity = 1;
    // Safety: The request and output structures are live and nonoverlapping.
    assert_eq!(
        unsafe { voice_retention_plan_v1(&raw const request, &raw mut output) },
        VOICE_STATUS_NULL_POINTER
    );
}

#[test]
fn version_one_layout_is_fixed() {
    assert_eq!(size_of::<VoiceSessionIdV1>(), 16);
    assert_eq!(size_of::<VoiceRetentionSettingsV1>(), 24);
    assert_eq!(size_of::<VoiceRetentionCandidateV1>(), 48);
    assert_eq!(size_of::<VoiceRetentionRequestV1>(), 56);
    assert_eq!(size_of::<VoiceRetentionDecisionV1>(), 32);
    assert_eq!(size_of::<VoiceRetentionPlanV1>(), 56);
}

fn candidates() -> [VoiceRetentionCandidateV1; 2] {
    [candidate([1; 16], 1_000), candidate([2; 16], 2_000)]
}

fn candidate(id: [u8; 16], ended_at: i64) -> VoiceRetentionCandidateV1 {
    VoiceRetentionCandidateV1 {
        session_id: VoiceSessionIdV1 { bytes: id },
        ended_at_unix_milliseconds: ended_at,
        audio_bytes: 10,
        recovery_expires_at_unix_milliseconds: 0,
        is_pinned: 0,
        is_active: 0,
        is_sole_recovery_artifact: 0,
        has_recovery_expires_at: 0,
        reserved: [0; 4],
    }
}

fn make_request(candidates: &[VoiceRetentionCandidateV1]) -> VoiceRetentionRequestV1 {
    VoiceRetentionRequestV1 {
        settings: VoiceRetentionSettingsV1 {
            has_maximum_age_days: 0,
            has_maximum_audio_bytes: 0,
            has_maximum_artifact_count: 1,
            reserved: 0,
            maximum_age_days: 0,
            maximum_artifact_count: 1,
            maximum_audio_bytes: 0,
        },
        now_unix_milliseconds: 3_000,
        low_disk_reclaim_bytes: 0,
        candidates: candidates.as_ptr(),
        candidate_count: candidates.len(),
    }
}

fn make_output(decisions: &mut [VoiceRetentionDecisionV1]) -> VoiceRetentionPlanV1 {
    VoiceRetentionPlanV1 {
        decisions: decisions.as_mut_ptr(),
        decision_capacity: decisions.len(),
        decision_count: 0,
        reclaimed_bytes: 0,
        low_disk_shortfall_bytes: 0,
        remaining_audio_bytes: 0,
        remaining_artifact_count: 0,
        exceeds_byte_limit: 0,
        exceeds_artifact_limit: 0,
        reserved: [0; 2],
    }
}

const fn empty_decision() -> VoiceRetentionDecisionV1 {
    VoiceRetentionDecisionV1 {
        session_id: VoiceSessionIdV1 { bytes: [0; 16] },
        reason: 0,
        reserved: 0,
        audio_bytes: 0,
    }
}
