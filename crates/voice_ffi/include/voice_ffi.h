#ifndef VOICE_FFI_H
#define VOICE_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VOICE_STATUS_OK UINT32_C(0)
#define VOICE_STATUS_NULL_POINTER UINT32_C(1)
#define VOICE_STATUS_INVALID_ARGUMENT UINT32_C(2)
#define VOICE_STATUS_BUFFER_TOO_SMALL UINT32_C(3)
#define VOICE_STATUS_INTERNAL_FAILURE UINT32_C(4)
#define VOICE_STATUS_INVALID_AGE_LIMIT UINT32_C(5)
#define VOICE_STATUS_INVALID_ARTIFACT_LIMIT UINT32_C(6)
#define VOICE_STATUS_INVALID_BYTE_LIMIT UINT32_C(7)
#define VOICE_STATUS_INVALID_RECLAIM_REQUEST UINT32_C(8)
#define VOICE_STATUS_INVALID_ARTIFACT_SIZE UINT32_C(9)
#define VOICE_STATUS_INVALID_SESSION_ID UINT32_C(10)
#define VOICE_STATUS_DUPLICATE_SESSION_ID UINT32_C(11)
#define VOICE_STATUS_INVALID_TIMESTAMP UINT32_C(12)
#define VOICE_STATUS_TOO_MANY_CANDIDATES UINT32_C(13)
#define VOICE_STATUS_INVALID_UTF8_PATH UINT32_C(14)
#define VOICE_STATUS_INVALID_MODEL_PACKAGE_ROOT UINT32_C(15)
#define VOICE_STATUS_INVALID_MODEL_PACKAGE_MANIFEST UINT32_C(16)
#define VOICE_STATUS_MODEL_PACKAGE_LIMIT_EXCEEDED UINT32_C(17)
#define VOICE_STATUS_MODEL_PACKAGE_INVENTORY_INVALID UINT32_C(18)
#define VOICE_STATUS_MODEL_PACKAGE_DIGEST_MISMATCH UINT32_C(19)
#define VOICE_STATUS_MODEL_PACKAGE_IO_FAILURE UINT32_C(20)
#define VOICE_STATUS_INVALID_HISTORY_ARCHIVE_ROOT UINT32_C(21)
#define VOICE_STATUS_INVALID_HISTORY_ARCHIVE_MANIFEST UINT32_C(22)
#define VOICE_STATUS_HISTORY_ARCHIVE_LIMIT_EXCEEDED UINT32_C(23)
#define VOICE_STATUS_HISTORY_ARCHIVE_INVENTORY_INVALID UINT32_C(24)
#define VOICE_STATUS_HISTORY_ARCHIVE_INTEGRITY_MISMATCH UINT32_C(25)
#define VOICE_STATUS_HISTORY_ARCHIVE_IDENTITY_INVALID UINT32_C(26)
#define VOICE_STATUS_HISTORY_ARCHIVE_IO_FAILURE UINT32_C(27)

#define VOICE_EXPIRATION_AGE_LIMIT UINT32_C(1)
#define VOICE_EXPIRATION_ARTIFACT_LIMIT UINT32_C(2)
#define VOICE_EXPIRATION_BYTE_LIMIT UINT32_C(3)
#define VOICE_EXPIRATION_LOW_DISK UINT32_C(4)
#define VOICE_EXPIRATION_RECOVERY_LIMIT UINT32_C(5)

#define VOICE_MODEL_RUNTIME_SHERPA_ONNX UINT32_C(1)
#define VOICE_MODEL_RUNTIME_WHISPER_CPP UINT32_C(2)
#define VOICE_MODEL_RUNTIME_MISTRAL_RS UINT32_C(3)
#define VOICE_MODEL_RUNTIME_LLAMA_CPP UINT32_C(4)

#define VOICE_MODEL_STAGE_ASR UINT32_C(1)
#define VOICE_MODEL_STAGE_FORMATTING UINT32_C(2)
#define VOICE_MODEL_STAGE_VAD UINT32_C(3)

#define VOICE_MODEL_CAPABILITY_STREAMING_ASR UINT32_C(1)
#define VOICE_MODEL_CAPABILITY_FILE_ASR UINT32_C(2)
#define VOICE_MODEL_CAPABILITY_FORMATTING UINT32_C(4)
#define VOICE_MODEL_CAPABILITY_VAD UINT32_C(8)

typedef uint32_t VoiceStatusV1;

typedef struct VoiceUtf8BufferV1 {
  uint8_t *bytes;
  size_t capacity;
  size_t length;
} VoiceUtf8BufferV1;

typedef struct VoiceModelPackageRequestV1 {
  const uint8_t *root_path_utf8;
  size_t root_path_length;
  uint64_t maximum_manifest_bytes;
  uint64_t maximum_installed_bytes;
  uint32_t maximum_file_count;
  uint8_t has_expected_manifest_sha256;
  uint8_t reserved[3];
  uint8_t expected_manifest_sha256[32];
} VoiceModelPackageRequestV1;

typedef struct VoiceModelPackageInfoV1 {
  VoiceUtf8BufferV1 package_id;
  VoiceUtf8BufferV1 version;
  VoiceUtf8BufferV1 display_name;
  VoiceUtf8BufferV1 spdx_expression;
  VoiceUtf8BufferV1 notice_file;
  VoiceUtf8BufferV1 source_url;
  uint32_t runtime;
  uint32_t stage;
  uint32_t capability_mask;
  uint32_t file_count;
  uint64_t verified_bytes;
  uint64_t minimum_memory_bytes;
  uint64_t recommended_memory_bytes;
  uint8_t manifest_sha256[32];
  uint8_t reserved[8];
} VoiceModelPackageInfoV1;

typedef struct VoiceHistoryArchiveRequestV1 {
  const uint8_t *root_path_utf8;
  size_t root_path_length;
  uint64_t maximum_manifest_bytes;
  uint64_t maximum_checksum_bytes;
  uint64_t maximum_audio_bytes;
  uint32_t maximum_result_count;
  uint8_t reserved[4];
} VoiceHistoryArchiveRequestV1;

typedef struct VoiceHistoryArchiveInfoV1 {
  uint8_t session_id[16];
  uint32_t result_count;
  uint8_t has_audio;
  uint8_t reserved[3];
  uint64_t verified_bytes;
  uint8_t manifest_sha256[32];
} VoiceHistoryArchiveInfoV1;

typedef struct VoiceSessionIdV1 {
  uint8_t bytes[16];
} VoiceSessionIdV1;

typedef struct VoiceRetentionSettingsV1 {
  uint8_t has_maximum_age_days;
  uint8_t has_maximum_audio_bytes;
  uint8_t has_maximum_artifact_count;
  uint8_t reserved;
  uint32_t maximum_age_days;
  uint32_t maximum_artifact_count;
  int64_t maximum_audio_bytes;
} VoiceRetentionSettingsV1;

typedef struct VoiceRetentionCandidateV1 {
  VoiceSessionIdV1 session_id;
  int64_t ended_at_unix_milliseconds;
  int64_t audio_bytes;
  int64_t recovery_expires_at_unix_milliseconds;
  uint8_t is_pinned;
  uint8_t is_active;
  uint8_t is_sole_recovery_artifact;
  uint8_t has_recovery_expires_at;
  uint8_t reserved[4];
} VoiceRetentionCandidateV1;

typedef struct VoiceRetentionRequestV1 {
  VoiceRetentionSettingsV1 settings;
  int64_t now_unix_milliseconds;
  int64_t low_disk_reclaim_bytes;
  const VoiceRetentionCandidateV1 *candidates;
  size_t candidate_count;
} VoiceRetentionRequestV1;

typedef struct VoiceRetentionDecisionV1 {
  VoiceSessionIdV1 session_id;
  uint32_t reason;
  uint32_t reserved;
  int64_t audio_bytes;
} VoiceRetentionDecisionV1;

typedef struct VoiceRetentionPlanV1 {
  VoiceRetentionDecisionV1 *decisions;
  size_t decision_capacity;
  size_t decision_count;
  int64_t reclaimed_bytes;
  int64_t low_disk_shortfall_bytes;
  int64_t remaining_audio_bytes;
  uint32_t remaining_artifact_count;
  uint8_t exceeds_byte_limit;
  uint8_t exceeds_artifact_limit;
  uint8_t reserved[2];
} VoiceRetentionPlanV1;

/*
 * All declared array elements must remain valid and aligned for the call.
 * Pointers are never retained. Reserved bytes must be zero. Boolean and
 * optional-presence fields accept only 0 or 1. The request, output structure,
 * and declared arrays must not overlap. On BUFFER_TOO_SMALL, decision_count
 * reports the required caller-owned capacity.
 */
VoiceStatusV1 voice_retention_plan_v1(const VoiceRetentionRequestV1 *request,
                                      VoiceRetentionPlanV1 *output);

/*
 * The path is UTF-8 and pointers are never retained. Keep the staging package
 * private from concurrent mutation during validation. A present expected
 * manifest digest authenticates exact manifest bytes against an external
 * catalog. Output text is not null terminated. Reserved bytes must be zero. On
 * BUFFER_TOO_SMALL, each text length reports its required capacity and no text
 * buffer changes.
 */
VoiceStatusV1
voice_model_package_validate_v1(const VoiceModelPackageRequestV1 *request,
                                VoiceModelPackageInfoV1 *output);

/*
 * The archive-root path is UTF-8 and pointers are never retained. Keep the
 * source directory private from concurrent mutation during validation.
 * Reserved bytes must be zero. The request and output must not overlap.
 */
VoiceStatusV1
voice_history_archive_validate_v1(const VoiceHistoryArchiveRequestV1 *request,
                                  VoiceHistoryArchiveInfoV1 *output);

#ifdef __cplusplus
}
#endif

#endif
