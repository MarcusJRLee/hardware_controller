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

#define VOICE_EXPIRATION_AGE_LIMIT UINT32_C(1)
#define VOICE_EXPIRATION_ARTIFACT_LIMIT UINT32_C(2)
#define VOICE_EXPIRATION_BYTE_LIMIT UINT32_C(3)
#define VOICE_EXPIRATION_LOW_DISK UINT32_C(4)
#define VOICE_EXPIRATION_RECOVERY_LIMIT UINT32_C(5)

typedef uint32_t VoiceStatusV1;

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

#ifdef __cplusplus
}
#endif

#endif
