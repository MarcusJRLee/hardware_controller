#include "voice_ffi.h"

#include <assert.h>
#include <string.h>

_Static_assert(sizeof(VoiceSessionIdV1) == 16, "VoiceSessionIdV1 layout");
_Static_assert(sizeof(VoiceRetentionSettingsV1) == 24,
               "VoiceRetentionSettingsV1 layout");
_Static_assert(sizeof(VoiceRetentionCandidateV1) == 48,
               "VoiceRetentionCandidateV1 layout");
_Static_assert(sizeof(VoiceRetentionRequestV1) == 56,
               "VoiceRetentionRequestV1 layout");
_Static_assert(sizeof(VoiceRetentionDecisionV1) == 32,
               "VoiceRetentionDecisionV1 layout");
_Static_assert(sizeof(VoiceRetentionPlanV1) == 56,
               "VoiceRetentionPlanV1 layout");
_Static_assert(sizeof(VoiceUtf8BufferV1) == 24, "VoiceUtf8BufferV1 layout");
_Static_assert(sizeof(VoiceModelPackageRequestV1) == 72,
               "VoiceModelPackageRequestV1 layout");
_Static_assert(sizeof(VoiceModelPackageInfoV1) == 224,
               "VoiceModelPackageInfoV1 layout");
_Static_assert(sizeof(VoiceModelPackageInfoV2) == 248,
               "VoiceModelPackageInfoV2 layout");
_Static_assert(sizeof(VoiceHistoryArchiveRequestV1) == 48,
               "VoiceHistoryArchiveRequestV1 layout");
_Static_assert(sizeof(VoiceHistoryArchiveInfoV1) == 64,
               "VoiceHistoryArchiveInfoV1 layout");

int main(int argc, char **argv) {
  assert(argc == 3);
  VoiceRetentionCandidateV1 candidates[2] = {0};
  memset(candidates[0].session_id.bytes, 1, 16);
  candidates[0].ended_at_unix_milliseconds = 1000;
  candidates[0].audio_bytes = 10;
  memset(candidates[1].session_id.bytes, 2, 16);
  candidates[1].ended_at_unix_milliseconds = 2000;
  candidates[1].audio_bytes = 10;

  VoiceRetentionRequestV1 request = {0};
  request.settings.has_maximum_artifact_count = 1;
  request.settings.maximum_artifact_count = 1;
  request.now_unix_milliseconds = 3000;
  request.candidates = candidates;
  request.candidate_count = 2;

  VoiceRetentionPlanV1 output = {0};
  assert(voice_retention_plan_v1(&request, &output) ==
         VOICE_STATUS_BUFFER_TOO_SMALL);
  assert(output.decision_count == 1);

  VoiceRetentionDecisionV1 decision = {0};
  output.decisions = &decision;
  output.decision_capacity = 1;
  assert(voice_retention_plan_v1(&request, &output) == VOICE_STATUS_OK);
  assert(output.decision_count == 1);
  assert(decision.session_id.bytes[0] == 1);
  assert(decision.reason == VOICE_EXPIRATION_ARTIFACT_LIMIT);
  assert(decision.audio_bytes == 10);

  VoiceModelPackageRequestV1 model_request = {0};
  model_request.root_path_utf8 = (const uint8_t *)argv[1];
  model_request.root_path_length = strlen(argv[1]);
  model_request.maximum_manifest_bytes = 1024 * 1024;
  model_request.maximum_installed_bytes = 1024 * 1024;
  model_request.maximum_file_count = 16;

  uint8_t package_id[128] = {0};
  uint8_t version[64] = {0};
  uint8_t display_name[128] = {0};
  uint8_t languages[10000] = {0};
  uint8_t spdx_expression[256] = {0};
  uint8_t notice_file[1024] = {0};
  uint8_t source_url[2048] = {0};
  VoiceModelPackageInfoV2 model_output = {0};
  model_output.base.package_id =
      (VoiceUtf8BufferV1){package_id, sizeof(package_id), 0};
  model_output.base.version = (VoiceUtf8BufferV1){version, sizeof(version), 0};
  model_output.base.display_name =
      (VoiceUtf8BufferV1){display_name, sizeof(display_name), 0};
  model_output.languages_csv =
      (VoiceUtf8BufferV1){languages, sizeof(languages), 0};
  model_output.base.spdx_expression =
      (VoiceUtf8BufferV1){spdx_expression, sizeof(spdx_expression), 0};
  model_output.base.notice_file =
      (VoiceUtf8BufferV1){notice_file, sizeof(notice_file), 0};
  model_output.base.source_url =
      (VoiceUtf8BufferV1){source_url, sizeof(source_url), 0};

  assert(voice_model_package_validate_v1(&model_request, &model_output.base) ==
         VOICE_STATUS_OK);
  assert(model_output.base.package_id.length == 36);
  assert(voice_model_package_validate_v2(&model_request, &model_output) ==
         VOICE_STATUS_OK);
  assert(model_output.base.package_id.length == 36);
  assert(memcmp(package_id, "com.longdevity.fixture.streaming_asr", 36) == 0);
  assert(model_output.base.runtime == VOICE_MODEL_RUNTIME_SHERPA_ONNX);
  assert(model_output.base.stage == VOICE_MODEL_STAGE_ASR);
  assert(model_output.languages_csv.length == 5);
  assert(memcmp(languages, "en-US", 5) == 0);
  assert(
      model_output.base.capability_mask ==
      (VOICE_MODEL_CAPABILITY_STREAMING_ASR | VOICE_MODEL_CAPABILITY_FILE_ASR));
  assert(model_output.base.file_count == 2);
  assert(model_output.base.verified_bytes == 73);
  uint8_t zero_digest[32] = {0};
  assert(memcmp(model_output.base.manifest_sha256, zero_digest, 32) != 0);

  VoiceHistoryArchiveRequestV1 archive_request = {0};
  archive_request.root_path_utf8 = (const uint8_t *)argv[2];
  archive_request.root_path_length = strlen(argv[2]);
  archive_request.maximum_manifest_bytes = 16 * 1024 * 1024;
  archive_request.maximum_checksum_bytes = 256 * 1024;
  archive_request.maximum_audio_bytes = (uint64_t)2 * 1024 * 1024 * 1024;
  archive_request.maximum_result_count = 10000;
  VoiceHistoryArchiveInfoV1 archive_output = {0};
  assert(voice_history_archive_validate_v1(&archive_request, &archive_output) ==
         VOICE_STATUS_OK);
  assert(archive_output.session_id[15] == 1);
  assert(archive_output.result_count == 4);
  assert(archive_output.has_audio == 0);
  assert(archive_output.verified_bytes != 0);
  assert(memcmp(archive_output.manifest_sha256, zero_digest, 32) != 0);
  return 0;
}
