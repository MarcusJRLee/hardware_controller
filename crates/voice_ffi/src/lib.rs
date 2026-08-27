//! Versioned synchronous C ABI for the portable Voice engine.

use std::{panic::AssertUnwindSafe, path::Path, slice};

use voice_archive::{HistoryArchiveError, HistoryArchiveLimits, validate_history_archive};
use voice_core::{
    AudioExpirationReason, RetentionCandidate, RetentionError, RetentionSettings, SessionId,
    plan_retention,
};
use voice_models::{
    ModelCapability, ModelPackageError, ModelPackageLimits, ModelRuntime, ModelStage,
    ValidatedModelPackage, validate_model_package,
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
/// A package root path is not valid UTF-8.
pub const VOICE_STATUS_INVALID_UTF8_PATH: u32 = 14;
/// A package root is absent, linked, or not a directory.
pub const VOICE_STATUS_INVALID_MODEL_PACKAGE_ROOT: u32 = 15;
/// A package manifest or its typed metadata is invalid.
pub const VOICE_STATUS_INVALID_MODEL_PACKAGE_MANIFEST: u32 = 16;
/// A package exceeds a configured manifest, byte, or file-count limit.
pub const VOICE_STATUS_MODEL_PACKAGE_LIMIT_EXCEEDED: u32 = 17;
/// A package inventory is incomplete, linked, duplicated, or undeclared.
pub const VOICE_STATUS_MODEL_PACKAGE_INVENTORY_INVALID: u32 = 18;
/// A declared file size or digest does not match its bytes.
pub const VOICE_STATUS_MODEL_PACKAGE_DIGEST_MISMATCH: u32 = 19;
/// Package verification could not read the complete input.
pub const VOICE_STATUS_MODEL_PACKAGE_IO_FAILURE: u32 = 20;
/// A Voice History archive root is absent, linked, or not a directory.
pub const VOICE_STATUS_INVALID_HISTORY_ARCHIVE_ROOT: u32 = 21;
/// A Voice History archive manifest or checksum contract is invalid.
pub const VOICE_STATUS_INVALID_HISTORY_ARCHIVE_MANIFEST: u32 = 22;
/// A Voice History archive exceeds a configured resource limit.
pub const VOICE_STATUS_HISTORY_ARCHIVE_LIMIT_EXCEEDED: u32 = 23;
/// A Voice History archive inventory is incomplete, linked, or undeclared.
pub const VOICE_STATUS_HISTORY_ARCHIVE_INVENTORY_INVALID: u32 = 24;
/// A Voice History archive digest does not match its bytes.
pub const VOICE_STATUS_HISTORY_ARCHIVE_INTEGRITY_MISMATCH: u32 = 25;
/// A Voice History archive contains contradictory session identities.
pub const VOICE_STATUS_HISTORY_ARCHIVE_IDENTITY_INVALID: u32 = 26;
/// Voice History archive verification could not read the complete input.
pub const VOICE_STATUS_HISTORY_ARCHIVE_IO_FAILURE: u32 = 27;

/// Versioned Voice History archive validation request.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct VoiceHistoryArchiveRequestV1 {
    /// UTF-8 archive-root path bytes.
    pub root_path_utf8: *const u8,
    /// Number of readable path bytes.
    pub root_path_length: usize,
    /// Maximum readable manifest bytes.
    pub maximum_manifest_bytes: u64,
    /// Maximum readable checksum-file bytes.
    pub maximum_checksum_bytes: u64,
    /// Maximum optional audio-artifact bytes.
    pub maximum_audio_bytes: u64,
    /// Maximum immutable History results.
    pub maximum_result_count: u32,
    /// Must contain only zeroes.
    pub reserved: [u8; 4],
}

/// Verified Voice History archive metadata.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct VoiceHistoryArchiveInfoV1 {
    /// Voice session UUID bytes in network order.
    pub session_id: [u8; 16],
    /// Number of verified immutable results.
    pub result_count: u32,
    /// Whether a verified audio artifact is present.
    pub has_audio: u8,
    /// Written as zeroes.
    pub reserved: [u8; 3],
    /// Total verified manifest and optional audio bytes.
    pub verified_bytes: u64,
    /// SHA-256 of the exact verified manifest bytes.
    pub manifest_sha256: [u8; 32],
}

/// Validates a Voice History archive without retaining pointers or files.
///
/// Keep the source directory private from concurrent mutation for the call.
///
/// # Safety
///
/// Every non-null pointer must be aligned and valid for its declared readable
/// or writable byte count for the duration of this call. Input and output must
/// not overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn voice_history_archive_validate_v1(
    request: *const VoiceHistoryArchiveRequestV1,
    output: *mut VoiceHistoryArchiveInfoV1,
) -> u32 {
    std::panic::catch_unwind(AssertUnwindSafe(|| {
        // Safety: Pointer validity and alignment are the documented C precondition.
        unsafe { validate_archive(request, output) }
    }))
    .unwrap_or(VOICE_STATUS_INTERNAL_FAILURE)
}

unsafe fn validate_archive(
    request: *const VoiceHistoryArchiveRequestV1,
    output: *mut VoiceHistoryArchiveInfoV1,
) -> u32 {
    if request.is_null() || output.is_null() {
        return VOICE_STATUS_NULL_POINTER;
    }
    // Safety: Null pointers were rejected and validity is the caller contract.
    let request = unsafe { &*request };
    // Safety: Null pointers were rejected and exclusive output is the caller contract.
    let output = unsafe { &mut *output };
    *output = VoiceHistoryArchiveInfoV1 {
        session_id: [0; 16],
        result_count: 0,
        has_audio: 0,
        reserved: [0; 3],
        verified_bytes: 0,
        manifest_sha256: [0; 32],
    };
    if request.root_path_utf8.is_null() {
        return VOICE_STATUS_NULL_POINTER;
    }
    if request.reserved != [0; 4]
        || request.maximum_manifest_bytes == 0
        || request.maximum_checksum_bytes == 0
        || request.maximum_result_count == 0
    {
        return VOICE_STATUS_INVALID_ARGUMENT;
    }
    // Safety: The caller promises this many readable path bytes.
    let path_bytes =
        unsafe { slice::from_raw_parts(request.root_path_utf8, request.root_path_length) };
    let Ok(path) = std::str::from_utf8(path_bytes) else {
        return VOICE_STATUS_INVALID_UTF8_PATH;
    };
    if path.is_empty() {
        return VOICE_STATUS_INVALID_ARGUMENT;
    }
    let archive = match validate_history_archive(
        Path::new(path),
        HistoryArchiveLimits {
            maximum_manifest_bytes: request.maximum_manifest_bytes,
            maximum_checksum_bytes: request.maximum_checksum_bytes,
            maximum_audio_bytes: request.maximum_audio_bytes,
            maximum_result_count: request.maximum_result_count,
        },
    ) {
        Ok(value) => value,
        Err(error) => return archive_status(&error),
    };
    output.session_id = archive.session_id;
    output.result_count = archive.result_count;
    output.has_audio = u8::from(archive.has_audio);
    output.verified_bytes = archive.verified_bytes;
    output.manifest_sha256 = archive.manifest_sha256;
    VOICE_STATUS_OK
}

fn archive_status(error: &HistoryArchiveError) -> u32 {
    match error {
        HistoryArchiveError::InvalidRoot => VOICE_STATUS_INVALID_HISTORY_ARCHIVE_ROOT,
        HistoryArchiveError::InvalidInventory => VOICE_STATUS_HISTORY_ARCHIVE_INVENTORY_INVALID,
        HistoryArchiveError::InvalidManifest | HistoryArchiveError::UnsupportedSchema => {
            VOICE_STATUS_INVALID_HISTORY_ARCHIVE_MANIFEST
        }
        HistoryArchiveError::LimitExceeded => VOICE_STATUS_HISTORY_ARCHIVE_LIMIT_EXCEEDED,
        HistoryArchiveError::IntegrityMismatch => VOICE_STATUS_HISTORY_ARCHIVE_INTEGRITY_MISMATCH,
        HistoryArchiveError::InvalidIdentity => VOICE_STATUS_HISTORY_ARCHIVE_IDENTITY_INVALID,
        HistoryArchiveError::Io => VOICE_STATUS_HISTORY_ARCHIVE_IO_FAILURE,
    }
}

/// One caller-owned UTF-8 output buffer.
#[repr(C)]
#[derive(Debug)]
pub struct VoiceUtf8BufferV1 {
    /// Writable bytes, or null only when `capacity` is zero.
    pub bytes: *mut u8,
    /// Number of writable bytes.
    pub capacity: usize,
    /// Required or written byte count, without a null terminator.
    pub length: usize,
}

/// Versioned local Model-package validation request.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct VoiceModelPackageRequestV1 {
    /// UTF-8 package-root path bytes.
    pub root_path_utf8: *const u8,
    /// Number of readable path bytes.
    pub root_path_length: usize,
    /// Maximum readable manifest bytes.
    pub maximum_manifest_bytes: u64,
    /// Maximum declared payload bytes.
    pub maximum_installed_bytes: u64,
    /// Maximum declared payload files.
    pub maximum_file_count: u32,
    /// Whether an authenticated manifest digest is supplied.
    pub has_expected_manifest_sha256: u8,
    /// Must contain only zeroes.
    pub reserved: [u8; 3],
    /// Expected exact manifest SHA-256 when present.
    pub expected_manifest_sha256: [u8; 32],
}

/// Verified Model-package metadata in caller-owned buffers.
#[repr(C)]
#[derive(Debug)]
pub struct VoiceModelPackageInfoV1 {
    /// Stable package identifier.
    pub package_id: VoiceUtf8BufferV1,
    /// Publisher-controlled package version.
    pub version: VoiceUtf8BufferV1,
    /// User-visible package name.
    pub display_name: VoiceUtf8BufferV1,
    /// SPDX license expression.
    pub spdx_expression: VoiceUtf8BufferV1,
    /// Package-relative notice path.
    pub notice_file: VoiceUtf8BufferV1,
    /// Publisher or upstream source URL.
    pub source_url: VoiceUtf8BufferV1,
    /// Runtime code: sherpa-onnx 1, whisper.cpp 2, mistral.rs 3, llama.cpp 4.
    pub runtime: u32,
    /// Stage code: ASR 1, formatting 2, VAD 3.
    pub stage: u32,
    /// Capability bits: streaming ASR 1, file ASR 2, formatting 4, VAD 8.
    pub capability_mask: u32,
    /// Number of verified payload files.
    pub file_count: u32,
    /// Sum of verified payload bytes.
    pub verified_bytes: u64,
    /// Declared minimum working memory.
    pub minimum_memory_bytes: u64,
    /// Declared recommended working memory.
    pub recommended_memory_bytes: u64,
    /// SHA-256 of the exact verified manifest bytes.
    pub manifest_sha256: [u8; 32],
    /// Written as zeroes.
    pub reserved: [u8; 8],
}

/// V2 Model metadata preserving the complete V1 prefix.
#[repr(C)]
#[derive(Debug)]
pub struct VoiceModelPackageInfoV2 {
    /// Stable V1 metadata layout.
    pub base: VoiceModelPackageInfoV1,
    /// Comma-separated BCP-47-like language tags in manifest order.
    pub languages_csv: VoiceUtf8BufferV1,
}

/// Validates a package without retaining caller pointers or file handles.
///
/// The caller must provide valid, aligned pointers for declared lengths. Keep
/// the staging directory private from concurrent mutation for the call. Output
/// text is UTF-8 without null terminators. On `VOICE_STATUS_BUFFER_TOO_SMALL`,
/// every text length reports its required capacity and no text buffer changes.
///
/// # Safety
///
/// Every non-null pointer must be aligned and valid for its declared readable
/// or writable byte count for the duration of this call. Input, output, and all
/// declared buffers must not overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn voice_model_package_validate_v1(
    request: *const VoiceModelPackageRequestV1,
    output: *mut VoiceModelPackageInfoV1,
) -> u32 {
    std::panic::catch_unwind(AssertUnwindSafe(|| {
        // Safety: Pointer validity and alignment are the documented C precondition.
        unsafe { validate_package(request, output, None) }
    }))
    .unwrap_or(VOICE_STATUS_INTERNAL_FAILURE)
}

/// Validates a package and returns the V1 metadata plus ordered languages.
///
/// # Safety
///
/// The V1 safety contract applies to the V2 output and its language buffer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn voice_model_package_validate_v2(
    request: *const VoiceModelPackageRequestV1,
    output: *mut VoiceModelPackageInfoV2,
) -> u32 {
    std::panic::catch_unwind(AssertUnwindSafe(|| {
        if output.is_null() {
            return VOICE_STATUS_NULL_POINTER;
        }
        // Safety: Null was rejected and validity is the caller contract.
        let output = unsafe { &mut *output };
        // Safety: Pointer validity and alignment are the documented C precondition.
        unsafe {
            validate_package(
                request,
                &raw mut output.base,
                Some(&mut output.languages_csv),
            )
        }
    }))
    .unwrap_or(VOICE_STATUS_INTERNAL_FAILURE)
}

unsafe fn validate_package(
    request: *const VoiceModelPackageRequestV1,
    output: *mut VoiceModelPackageInfoV1,
    mut languages_csv: Option<&mut VoiceUtf8BufferV1>,
) -> u32 {
    if request.is_null() || output.is_null() {
        return VOICE_STATUS_NULL_POINTER;
    }
    // Safety: Null pointers were rejected and validity is the caller contract.
    let request = unsafe { &*request };
    // Safety: Null pointers were rejected and exclusive output is the caller contract.
    let output = unsafe { &mut *output };
    reset_model_output(output);
    if let Some(buffer) = languages_csv.as_deref_mut() {
        buffer.length = 0;
    }
    if request.root_path_utf8.is_null() {
        return VOICE_STATUS_NULL_POINTER;
    }
    if request.reserved != [0; 3]
        || request.has_expected_manifest_sha256 > 1
        || (request.has_expected_manifest_sha256 == 0
            && request.expected_manifest_sha256 != [0; 32])
        || request.maximum_manifest_bytes == 0
        || request.maximum_installed_bytes == 0
        || request.maximum_file_count == 0
    {
        return VOICE_STATUS_INVALID_ARGUMENT;
    }
    if has_null_output_buffer(output)
        || languages_csv
            .as_deref()
            .is_some_and(|buffer| buffer.capacity > 0 && buffer.bytes.is_null())
    {
        return VOICE_STATUS_NULL_POINTER;
    }

    // Safety: The caller promises this many readable path bytes.
    let path_bytes =
        unsafe { slice::from_raw_parts(request.root_path_utf8, request.root_path_length) };
    let Ok(path) = std::str::from_utf8(path_bytes) else {
        return VOICE_STATUS_INVALID_UTF8_PATH;
    };
    if path.is_empty() {
        return VOICE_STATUS_INVALID_ARGUMENT;
    }
    let package = match validate_model_package(
        Path::new(path),
        ModelPackageLimits {
            maximum_manifest_bytes: request.maximum_manifest_bytes,
            maximum_installed_bytes: request.maximum_installed_bytes,
            maximum_file_count: request.maximum_file_count,
        },
        (request.has_expected_manifest_sha256 == 1).then_some(request.expected_manifest_sha256),
    ) {
        Ok(value) => value,
        Err(error) => return model_status(&error),
    };
    set_model_metadata(output, &package);
    if let Some(buffer) = languages_csv.as_deref_mut() {
        buffer.length = languages_length(&package);
    }
    if model_output_is_too_small(output)
        || languages_csv
            .as_deref()
            .is_some_and(|buffer| buffer.capacity < buffer.length)
    {
        return VOICE_STATUS_BUFFER_TOO_SMALL;
    }

    // Safety: Buffer capacities were checked and their validity is the caller contract.
    unsafe { write_model_text(output, &package) };
    if let Some(buffer) = languages_csv {
        let languages = package.languages.join(",");
        if !languages.is_empty() {
            // Safety: Capacity was checked and the caller promises writable storage.
            unsafe {
                std::ptr::copy_nonoverlapping(languages.as_ptr(), buffer.bytes, languages.len());
            };
        }
    }
    VOICE_STATUS_OK
}

fn reset_model_output(output: &mut VoiceModelPackageInfoV1) {
    for buffer in [
        &mut output.package_id,
        &mut output.version,
        &mut output.display_name,
        &mut output.spdx_expression,
        &mut output.notice_file,
        &mut output.source_url,
    ] {
        buffer.length = 0;
    }
    output.runtime = 0;
    output.stage = 0;
    output.capability_mask = 0;
    output.file_count = 0;
    output.verified_bytes = 0;
    output.minimum_memory_bytes = 0;
    output.recommended_memory_bytes = 0;
    output.manifest_sha256 = [0; 32];
    output.reserved = [0; 8];
}

fn has_null_output_buffer(output: &VoiceModelPackageInfoV1) -> bool {
    [
        &output.package_id,
        &output.version,
        &output.display_name,
        &output.spdx_expression,
        &output.notice_file,
        &output.source_url,
    ]
    .iter()
    .any(|buffer| buffer.capacity > 0 && buffer.bytes.is_null())
}

fn set_model_metadata(output: &mut VoiceModelPackageInfoV1, package: &ValidatedModelPackage) {
    output.package_id.length = package.package_id.len();
    output.version.length = package.version.len();
    output.display_name.length = package.display_name.len();
    output.spdx_expression.length = package.license.spdx_expression.len();
    output.notice_file.length = package.license.notice_file.len();
    output.source_url.length = package.license.source_url.len();
    output.runtime = match package.runtime {
        ModelRuntime::SherpaOnnx => 1,
        ModelRuntime::WhisperCpp => 2,
        ModelRuntime::MistralRs => 3,
        ModelRuntime::LlamaCpp => 4,
    };
    output.stage = match package.stage {
        ModelStage::Asr => 1,
        ModelStage::Formatting => 2,
        ModelStage::Vad => 3,
    };
    output.capability_mask = package.capabilities.iter().fold(0, |mask, capability| {
        mask | match capability {
            ModelCapability::StreamingAsr => 1,
            ModelCapability::FileAsr => 2,
            ModelCapability::Formatting => 4,
            ModelCapability::Vad => 8,
        }
    });
    output.file_count = package.file_count;
    output.verified_bytes = package.verified_bytes;
    output.minimum_memory_bytes = package.resources.minimum_memory_bytes;
    output.recommended_memory_bytes = package.resources.recommended_memory_bytes;
    output.manifest_sha256 = package.manifest_sha256;
}

fn model_output_is_too_small(output: &VoiceModelPackageInfoV1) -> bool {
    [
        &output.package_id,
        &output.version,
        &output.display_name,
        &output.spdx_expression,
        &output.notice_file,
        &output.source_url,
    ]
    .iter()
    .any(|buffer| buffer.capacity < buffer.length)
}

unsafe fn write_model_text(output: &mut VoiceModelPackageInfoV1, package: &ValidatedModelPackage) {
    for (buffer, value) in [
        (&mut output.package_id, package.package_id.as_str()),
        (&mut output.version, package.version.as_str()),
        (&mut output.display_name, package.display_name.as_str()),
        (
            &mut output.spdx_expression,
            package.license.spdx_expression.as_str(),
        ),
        (
            &mut output.notice_file,
            package.license.notice_file.as_str(),
        ),
        (&mut output.source_url, package.license.source_url.as_str()),
    ] {
        if !value.is_empty() {
            // Safety: Capacity was checked and the caller promises writable storage.
            unsafe { std::ptr::copy_nonoverlapping(value.as_ptr(), buffer.bytes, value.len()) };
        }
    }
}

fn languages_length(package: &ValidatedModelPackage) -> usize {
    package
        .languages
        .iter()
        .map(String::len)
        .sum::<usize>()
        .saturating_add(package.languages.len().saturating_sub(1))
}

fn model_status(error: &ModelPackageError) -> u32 {
    match error {
        ModelPackageError::InvalidPackageRoot => VOICE_STATUS_INVALID_MODEL_PACKAGE_ROOT,
        ModelPackageError::ManifestBytesExceeded
        | ModelPackageError::FileCountExceeded
        | ModelPackageError::InstalledBytesExceeded => VOICE_STATUS_MODEL_PACKAGE_LIMIT_EXCEEDED,
        ModelPackageError::InvalidFilePath { .. }
        | ModelPackageError::DuplicateFilePath { .. }
        | ModelPackageError::MissingModelFile
        | ModelPackageError::MissingNoticeFile
        | ModelPackageError::SymbolicLink { .. }
        | ModelPackageError::UndeclaredFile { .. }
        | ModelPackageError::UndeclaredDirectory { .. }
        | ModelPackageError::MissingFile { .. } => VOICE_STATUS_MODEL_PACKAGE_INVENTORY_INVALID,
        ModelPackageError::ManifestDigestMismatch
        | ModelPackageError::FileSizeMismatch { .. }
        | ModelPackageError::DigestMismatch { .. } => VOICE_STATUS_MODEL_PACKAGE_DIGEST_MISMATCH,
        ModelPackageError::Io => VOICE_STATUS_MODEL_PACKAGE_IO_FAILURE,
        ModelPackageError::InvalidManifestFile
        | ModelPackageError::InvalidManifest
        | ModelPackageError::UnsupportedSchemaVersion
        | ModelPackageError::InvalidPackageId
        | ModelPackageError::InvalidVersion
        | ModelPackageError::InvalidDisplayName
        | ModelPackageError::InvalidLicense
        | ModelPackageError::InvalidResources
        | ModelPackageError::InvalidLanguage
        | ModelPackageError::DuplicateLanguage
        | ModelPackageError::DuplicateCapability
        | ModelPackageError::CapabilityStageMismatch
        | ModelPackageError::MissingCapability
        | ModelPackageError::InvalidDigest { .. }
        | ModelPackageError::InvalidFileSize { .. } => VOICE_STATUS_INVALID_MODEL_PACKAGE_MANIFEST,
    }
}

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
