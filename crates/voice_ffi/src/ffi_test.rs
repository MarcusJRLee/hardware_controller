use std::{
    mem::size_of,
    path::PathBuf,
    ptr,
    sync::atomic::{AtomicU64, Ordering},
};

static TEMPORARY_PACKAGE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

use crate::{
    VOICE_STATUS_ASR_RUNTIME_UNSUPPORTED, VOICE_STATUS_BUFFER_TOO_SMALL,
    VOICE_STATUS_HISTORY_ARCHIVE_LIMIT_EXCEEDED, VOICE_STATUS_INVALID_ARGUMENT,
    VOICE_STATUS_INVALID_RECLAIM_REQUEST, VOICE_STATUS_INVALID_UTF8_PATH,
    VOICE_STATUS_MODEL_PACKAGE_DIGEST_MISMATCH, VOICE_STATUS_NULL_POINTER, VOICE_STATUS_OK,
    VoiceASRModelInfoV1, VoiceHistoryArchiveInfoV1, VoiceHistoryArchiveRequestV1,
    VoiceModelPackageInfoV1, VoiceModelPackageInfoV2, VoiceModelPackageRequestV1,
    VoiceRetentionCandidateV1, VoiceRetentionDecisionV1, VoiceRetentionPlanV1,
    VoiceRetentionRequestV1, VoiceRetentionSettingsV1, VoiceSessionIdV1, VoiceUtf8BufferV1,
    voice_asr_model_resolve_v1, voice_history_archive_validate_v1, voice_model_package_validate_v1,
    voice_model_package_validate_v2, voice_retention_plan_v1,
};

#[test]
fn history_archive_validation_returns_verified_portable_metadata() {
    let root = archive_fixture_path();
    let root = root.to_string_lossy();
    let request = archive_request(root.as_bytes());
    let mut output = empty_archive_output();

    // Safety: Every pointer references live, aligned, nonoverlapping storage.
    let status = unsafe { voice_history_archive_validate_v1(&raw const request, &raw mut output) };

    assert_eq!(status, VOICE_STATUS_OK);
    assert_eq!(
        output.session_id,
        [0, 0, 0, 0, 0, 0, 64, 0, 128, 0, 0, 0, 0, 0, 0, 1]
    );
    assert_eq!(output.result_count, 4);
    assert_eq!(output.has_audio, 0);
    assert_ne!(output.verified_bytes, 0);
    assert_ne!(output.manifest_sha256, [0; 32]);
}

#[test]
fn history_archive_limits_remain_typed_across_the_abi() {
    let root = archive_fixture_path();
    let root = root.to_string_lossy();
    let mut request = archive_request(root.as_bytes());
    request.maximum_manifest_bytes = 1;
    let mut output = empty_archive_output();

    // Safety: Every pointer references live, aligned, nonoverlapping storage.
    let status = unsafe { voice_history_archive_validate_v1(&raw const request, &raw mut output) };

    assert_eq!(status, VOICE_STATUS_HISTORY_ARCHIVE_LIMIT_EXCEEDED);
    assert_eq!(output, empty_archive_output());
}

#[test]
fn model_package_validation_returns_verified_portable_metadata() {
    let root = fixture_path();
    let root = root.to_string_lossy();
    let request = model_request(root.as_bytes());
    let mut package_id = [0_u8; 128];
    let mut version = [0_u8; 64];
    let mut display_name = [0_u8; 128];
    let mut languages = [0_u8; 10_000];
    let mut spdx = [0_u8; 256];
    let mut notice = [0_u8; 1_024];
    let mut source_url = [0_u8; 2_048];
    let mut output = model_output(
        &mut package_id,
        &mut version,
        &mut display_name,
        &mut languages,
        &mut spdx,
        &mut notice,
        &mut source_url,
    );

    // Safety: Every pointer references live, aligned, nonoverlapping storage.
    let status = unsafe { voice_model_package_validate_v2(&raw const request, &raw mut output) };

    assert_eq!(status, VOICE_STATUS_OK);
    assert_eq!(
        utf8(&package_id, output.base.package_id.length),
        "com.longdevity.fixture.streaming_asr"
    );
    assert_eq!(utf8(&version, output.base.version.length), "1.0.0");
    assert_eq!(
        utf8(&display_name, output.base.display_name.length),
        "Fixture Streaming ASR"
    );
    assert_eq!(utf8(&languages, output.languages_csv.length), "en-US");
    assert_eq!(
        utf8(&spdx, output.base.spdx_expression.length),
        "Apache-2.0"
    );
    assert_eq!(utf8(&notice, output.base.notice_file.length), "NOTICE.txt");
    assert_eq!(output.base.runtime, 1);
    assert_eq!(output.base.stage, 1);
    assert_eq!(output.base.capability_mask, 3);
    assert_eq!(output.base.file_count, 2);
    assert_eq!(output.base.verified_bytes, 73);
    assert_ne!(output.base.manifest_sha256, [0; 32]);
}

#[test]
fn model_output_buffers_negotiate_without_partial_text() {
    let root = fixture_path();
    let root = root.to_string_lossy();
    let request = model_request(root.as_bytes());
    let mut package_id = [b'x'; 1];
    let mut output = model_output(
        &mut package_id,
        &mut [],
        &mut [],
        &mut [],
        &mut [],
        &mut [],
        &mut [],
    );

    // Safety: Every non-null pointer references live writable storage.
    let status = unsafe { voice_model_package_validate_v2(&raw const request, &raw mut output) };

    assert_eq!(status, VOICE_STATUS_BUFFER_TOO_SMALL);
    assert_eq!(output.base.package_id.length, 36);
    assert_eq!(output.base.version.length, 5);
    assert_eq!(package_id, [b'x']);
}

#[test]
fn model_package_v1_layout_and_function_remain_compatible() {
    let root = fixture_path();
    let root = root.to_string_lossy();
    let request = model_request(root.as_bytes());
    let mut package_id = [0_u8; 128];
    let mut output = model_output_v1(&mut package_id, &mut [], &mut [], &mut [], &mut [], &mut []);

    // Safety: Every pointer references live, aligned, nonoverlapping storage.
    let status = unsafe { voice_model_package_validate_v1(&raw const request, &raw mut output) };

    assert_eq!(status, VOICE_STATUS_BUFFER_TOO_SMALL);
    assert_eq!(output.package_id.length, 36);
    assert_eq!(size_of::<VoiceModelPackageInfoV1>(), 224);
}

#[test]
fn model_package_v2_null_output_fails_closed() {
    let root = fixture_path();
    let root = root.to_string_lossy();
    let request = model_request(root.as_bytes());

    // Safety: The function explicitly accepts null to report a typed error.
    let status = unsafe { voice_model_package_validate_v2(&raw const request, ptr::null_mut()) };

    assert_eq!(status, VOICE_STATUS_NULL_POINTER);
}

#[test]
fn model_package_failures_remain_typed_across_the_abi() {
    let invalid_path = [0xff_u8];
    let invalid_request = model_request(&invalid_path);
    let mut output = empty_model_output();
    // Safety: The input byte and output structures remain live for the call.
    assert_eq!(
        unsafe { voice_model_package_validate_v1(&raw const invalid_request, &raw mut output) },
        VOICE_STATUS_INVALID_UTF8_PATH
    );

    let root = fixture_path();
    let root = root.to_string_lossy();
    let mut wrong_digest_request = model_request(root.as_bytes());
    wrong_digest_request.has_expected_manifest_sha256 = 1;
    // Safety: The path and output structures remain live for the call.
    assert_eq!(
        unsafe {
            voice_model_package_validate_v1(&raw const wrong_digest_request, &raw mut output)
        },
        VOICE_STATUS_MODEL_PACKAGE_DIGEST_MISMATCH
    );
    let mut ambiguous_request = model_request(root.as_bytes());
    ambiguous_request.expected_manifest_sha256[0] = 1;
    // Safety: The path and output structures remain live for the call.
    assert_eq!(
        unsafe { voice_model_package_validate_v1(&raw const ambiguous_request, &raw mut output) },
        VOICE_STATUS_INVALID_ARGUMENT
    );

    let temporary = temporary_package();
    let model_path = temporary.join("model.bin");
    let mut bytes = std::fs::read(&model_path).expect("The model fixture must be readable.");
    bytes[0] ^= 1;
    std::fs::write(model_path, bytes).expect("The temporary model must be writable.");
    let path = temporary.to_string_lossy();
    let request = model_request(path.as_bytes());
    // Safety: The path and output structures remain live for the call.
    assert_eq!(
        unsafe { voice_model_package_validate_v1(&raw const request, &raw mut output) },
        VOICE_STATUS_MODEL_PACKAGE_DIGEST_MISMATCH
    );
    std::fs::remove_dir_all(temporary).expect("The exact temporary package must be removable.");
}

#[test]
fn asr_model_resolution_revalidates_digest_and_returns_only_whisper_model_path() {
    let temporary = temporary_package();
    let manifest_path = temporary.join("manifest.json");
    let manifest = std::fs::read_to_string(&manifest_path).expect("manifest readable");
    std::fs::write(
        &manifest_path,
        manifest.replace(
            "\"runtime\": \"sherpa_onnx\"",
            "\"runtime\": \"whisper_cpp\"",
        ),
    )
    .expect("manifest writable");
    let path = temporary.to_string_lossy();
    let mut validation_request = model_request(path.as_bytes());
    let mut validation_output = empty_model_output();
    // Safety: Input and output remain live and nonoverlapping for the call.
    assert_eq!(
        unsafe {
            voice_model_package_validate_v1(
                &raw const validation_request,
                &raw mut validation_output,
            )
        },
        VOICE_STATUS_BUFFER_TOO_SMALL
    );
    validation_request.has_expected_manifest_sha256 = 1;
    validation_request.expected_manifest_sha256 = validation_output.manifest_sha256;
    let mut model_path = [0_u8; 4_096];
    let mut output = VoiceASRModelInfoV1 {
        model_path: utf8_buffer(&mut model_path),
        manifest_sha256: [0; 32],
        reserved: [1; 8],
    };

    // Safety: Input and output remain live and nonoverlapping for the call.
    let status =
        unsafe { voice_asr_model_resolve_v1(&raw const validation_request, &raw mut output) };

    assert_eq!(status, VOICE_STATUS_OK);
    assert_eq!(
        utf8(&model_path, output.model_path.length),
        temporary.join("model.bin").to_string_lossy()
    );
    assert_eq!(output.manifest_sha256, validation_output.manifest_sha256);
    assert_eq!(output.reserved, [0; 8]);
    std::fs::remove_dir_all(temporary).expect("temporary package removable");
}

#[test]
fn asr_model_resolution_rejects_unpinned_or_wrong_runtime_packages() {
    let root = fixture_path();
    let path = root.to_string_lossy();
    let mut request = model_request(path.as_bytes());
    let mut model_path = [0_u8; 4_096];
    let mut output = VoiceASRModelInfoV1 {
        model_path: utf8_buffer(&mut model_path),
        manifest_sha256: [1; 32],
        reserved: [1; 8],
    };
    // Safety: Input and output remain live and nonoverlapping for each call.
    assert_eq!(
        unsafe { voice_asr_model_resolve_v1(&raw const request, &raw mut output) },
        VOICE_STATUS_INVALID_ARGUMENT
    );

    let mut validation_output = empty_model_output();
    // Safety: Input and output remain live and nonoverlapping for the call.
    let _ =
        unsafe { voice_model_package_validate_v1(&raw const request, &raw mut validation_output) };
    request.has_expected_manifest_sha256 = 1;
    request.expected_manifest_sha256 = validation_output.manifest_sha256;
    // Safety: Input and output remain live and nonoverlapping for the call.
    assert_eq!(
        unsafe { voice_asr_model_resolve_v1(&raw const request, &raw mut output) },
        VOICE_STATUS_ASR_RUNTIME_UNSUPPORTED
    );
}

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
    assert_eq!(size_of::<VoiceUtf8BufferV1>(), 24);
    assert_eq!(size_of::<VoiceModelPackageRequestV1>(), 72);
    assert_eq!(size_of::<VoiceModelPackageInfoV1>(), 224);
    assert_eq!(size_of::<VoiceModelPackageInfoV2>(), 248);
    assert_eq!(size_of::<VoiceASRModelInfoV1>(), 64);
    assert_eq!(size_of::<VoiceHistoryArchiveRequestV1>(), 48);
    assert_eq!(size_of::<VoiceHistoryArchiveInfoV1>(), 64);
}

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Tests/cuj/voice_model_package_v1/valid")
}

fn archive_fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Tests/cuj/voice_history_archive_v1/valid")
}

fn archive_request(path: &[u8]) -> VoiceHistoryArchiveRequestV1 {
    VoiceHistoryArchiveRequestV1 {
        root_path_utf8: path.as_ptr(),
        root_path_length: path.len(),
        maximum_manifest_bytes: 16 * 1_024 * 1_024,
        maximum_checksum_bytes: 256 * 1_024,
        maximum_audio_bytes: 2 * 1_024 * 1_024 * 1_024,
        maximum_result_count: 10_000,
        reserved: [0; 4],
    }
}

fn empty_archive_output() -> VoiceHistoryArchiveInfoV1 {
    VoiceHistoryArchiveInfoV1 {
        session_id: [0; 16],
        result_count: 0,
        has_audio: 0,
        reserved: [0; 3],
        verified_bytes: 0,
        manifest_sha256: [0; 32],
    }
}

fn temporary_package() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "hardware_controller_voice_model_ffi_{}_{}",
        std::process::id(),
        TEMPORARY_PACKAGE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir(&path).expect("The temporary package must be creatable.");
    for name in ["manifest.json", "model.bin", "NOTICE.txt"] {
        std::fs::copy(fixture_path().join(name), path.join(name))
            .expect("The model fixture must be copyable.");
    }
    path
}

fn model_request(path: &[u8]) -> VoiceModelPackageRequestV1 {
    VoiceModelPackageRequestV1 {
        root_path_utf8: path.as_ptr(),
        root_path_length: path.len(),
        maximum_manifest_bytes: 1_048_576,
        maximum_installed_bytes: 1_048_576,
        maximum_file_count: 16,
        has_expected_manifest_sha256: 0,
        reserved: [0; 3],
        expected_manifest_sha256: [0; 32],
    }
}

fn model_output<'a>(
    package_id: &'a mut [u8],
    version: &'a mut [u8],
    display_name: &'a mut [u8],
    languages: &'a mut [u8],
    spdx_expression: &'a mut [u8],
    notice_file: &'a mut [u8],
    source_url: &'a mut [u8],
) -> VoiceModelPackageInfoV2 {
    VoiceModelPackageInfoV2 {
        base: model_output_v1(
            package_id,
            version,
            display_name,
            spdx_expression,
            notice_file,
            source_url,
        ),
        languages_csv: utf8_buffer(languages),
    }
}

fn model_output_v1(
    package_id: &mut [u8],
    version: &mut [u8],
    display_name: &mut [u8],
    spdx_expression: &mut [u8],
    notice_file: &mut [u8],
    source_url: &mut [u8],
) -> VoiceModelPackageInfoV1 {
    VoiceModelPackageInfoV1 {
        package_id: utf8_buffer(package_id),
        version: utf8_buffer(version),
        display_name: utf8_buffer(display_name),
        spdx_expression: utf8_buffer(spdx_expression),
        notice_file: utf8_buffer(notice_file),
        source_url: utf8_buffer(source_url),
        runtime: 0,
        stage: 0,
        capability_mask: 0,
        file_count: 0,
        verified_bytes: 0,
        minimum_memory_bytes: 0,
        recommended_memory_bytes: 0,
        manifest_sha256: [0; 32],
        reserved: [0; 8],
    }
}

fn empty_model_output() -> VoiceModelPackageInfoV1 {
    model_output_v1(&mut [], &mut [], &mut [], &mut [], &mut [], &mut [])
}

fn utf8_buffer(bytes: &mut [u8]) -> VoiceUtf8BufferV1 {
    VoiceUtf8BufferV1 {
        bytes: bytes.as_mut_ptr(),
        capacity: bytes.len(),
        length: 0,
    }
}

fn utf8(bytes: &[u8], length: usize) -> &str {
    std::str::from_utf8(&bytes[..length]).expect("Validated output must be UTF-8.")
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
