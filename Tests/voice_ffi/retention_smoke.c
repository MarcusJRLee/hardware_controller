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

int main(void) {
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
  return 0;
}
