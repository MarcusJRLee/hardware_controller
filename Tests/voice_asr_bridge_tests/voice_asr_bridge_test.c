#include "asr_test_support.h"
#include "voice_asr_bridge.h"

#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double elapsed_seconds(struct timespec start, struct timespec end) {
  return (double)(end.tv_sec - start.tv_sec) +
         (double)(end.tv_nsec - start.tv_nsec) / 1000000000.0;
}

typedef struct Fixture {
  VoiceASRContext *context;
  float *samples;
  size_t sample_count;
} Fixture;

static VoiceASRRequestV1 request(uint8_t detect_speech) {
  return (VoiceASRRequestV1){
      .language_utf8 = "en",
      .detect_speech = detect_speech,
  };
}

static uint32_t transcribe(Fixture *fixture, const float *samples,
                           size_t sample_count,
                           const VoiceASRRequestV1 *parameters,
                           uint8_t *transcript, size_t transcript_capacity,
                           VoiceASRSegmentV1 *segments, size_t segment_capacity,
                           VoiceASRResultV1 *result) {
  *result = (VoiceASRResultV1){
      .transcript_utf8 = transcript,
      .transcript_capacity = transcript_capacity,
      .segments = segments,
      .segment_capacity = segment_capacity,
  };
  return voice_asr_transcribe_v1(fixture->context, samples, sample_count,
                                 parameters, result);
}

static int check_segments(const VoiceASRSegmentV1 *segments, size_t count,
                          size_t transcript_length, int64_t audio_ms) {
  size_t expected_offset = 0;
  int64_t previous_end = 0;
  for (size_t index = 0; index < count; index += 1) {
    if (segments[index].text_offset != expected_offset ||
        segments[index].start_milliseconds < previous_end ||
        segments[index].end_milliseconds < segments[index].start_milliseconds ||
        segments[index].end_milliseconds > audio_ms) {
      return 1;
    }
    expected_offset += segments[index].text_length;
    previous_end = segments[index].end_milliseconds;
  }
  return expected_offset == transcript_length ? 0 : 1;
}

static int check_contracts(Fixture *fixture) {
  VoiceASRContextInfoV1 info = {0};
  if (voice_asr_context_info_v1(fixture->context, &info) !=
          VOICE_ASR_STATUS_OK ||
      info.supports_vocabulary != 1 || info.supports_speech_detection != 1) {
    return 20;
  }
  VoiceASRResultV1 result = {0};
  VoiceASRRequestV1 uppercase = request(0);
  uppercase.language_utf8 = "EN";
  if (transcribe(fixture, fixture->samples, fixture->sample_count, &uppercase,
                 NULL, 0, NULL, 0,
                 &result) != VOICE_ASR_STATUS_INVALID_ARGUMENT) {
    return 21;
  }
  VoiceASRRequestV1 reserved = request(0);
  reserved.reserved[0] = 1;
  if (transcribe(fixture, fixture->samples, fixture->sample_count, &reserved,
                 NULL, 0, NULL, 0,
                 &result) != VOICE_ASR_STATUS_INVALID_ARGUMENT) {
    return 22;
  }
  VoiceASRRequestV1 missing_terms = request(0);
  missing_terms.vocabulary_count = 1;
  if (transcribe(fixture, fixture->samples, fixture->sample_count,
                 &missing_terms, NULL, 0, NULL, 0,
                 &result) != VOICE_ASR_STATUS_INVALID_ARGUMENT) {
    return 23;
  }
  uint8_t protected_transcript = 0xA5;
  VoiceASRSegmentV1 protected_segment = {.start_milliseconds = 17,
                                         .text_length = 29};
  const VoiceASRRequestV1 whole = request(0);
  if (transcribe(fixture, fixture->samples, fixture->sample_count, &whole,
                 &protected_transcript, 1, &protected_segment, 1,
                 &result) != VOICE_ASR_STATUS_BUFFER_TOO_SMALL ||
      result.transcript_length <= 1 || protected_transcript != 0xA5 ||
      protected_segment.start_milliseconds != 17 ||
      protected_segment.text_length != 29) {
    return 24;
  }
  float *silence = calloc(16000 * 3, sizeof(*silence));
  if (silence == NULL) {
    return 25;
  }
  const VoiceASRRequestV1 detected = request(1);
  const uint32_t silent_status = transcribe(
      fixture, silence, 16000 * 3, &detected, NULL, 0, NULL, 0, &result);
  free(silence);
  if (silent_status != VOICE_ASR_STATUS_NO_SPEECH ||
      result.transcript_length != 0 || result.decoded_chunk_count != 0) {
    return 26;
  }
  return 0;
}

static int check_transcript(Fixture *fixture, uint8_t detect_speech,
                            const char *const *vocabulary,
                            uint32_t vocabulary_count,
                            double maximum_real_time_factor) {
  uint8_t transcript[4096] = {0};
  VoiceASRSegmentV1 segments[64] = {0};
  VoiceASRResultV1 result = {0};
  VoiceASRRequestV1 parameters = request(detect_speech);
  parameters.vocabulary_utf8 = vocabulary;
  parameters.vocabulary_count = vocabulary_count;
  struct timespec start = {0};
  struct timespec end = {0};
  clock_gettime(CLOCK_MONOTONIC, &start);
  const uint32_t status =
      transcribe(fixture, fixture->samples, fixture->sample_count, &parameters,
                 transcript, sizeof(transcript) - 1, segments,
                 sizeof(segments) / sizeof(segments[0]), &result);
  clock_gettime(CLOCK_MONOTONIC, &end);
  if (status != VOICE_ASR_STATUS_OK || result.transcript_length == 0 ||
      result.segment_count == 0 || result.decoded_chunk_count == 0) {
    return 30;
  }
  transcript[result.transcript_length] = '\0';
  if (strstr((const char *)transcript, "ask not what your country") == NULL) {
    fprintf(stderr, "Unexpected transcript: %s\n", transcript);
    return 31;
  }
  const int64_t audio_ms = (int64_t)(fixture->sample_count / 16);
  if (check_segments(segments, result.segment_count, result.transcript_length,
                     audio_ms) != 0) {
    return 32;
  }
  const double audio_seconds = (double)fixture->sample_count / 16000.0;
  const double inference_seconds = elapsed_seconds(start, end);
  fprintf(stdout,
          "detect_speech=%u vocabulary=%u chunks=%u inference_seconds=%.6f "
          "real_time_factor=%.6f\n",
          detect_speech, vocabulary_count, result.decoded_chunk_count,
          inference_seconds, inference_seconds / audio_seconds);
  if (maximum_real_time_factor > 0.0 &&
      inference_seconds / audio_seconds > maximum_real_time_factor) {
    return 33;
  }
  return 0;
}

/*
 * Three copies separated by two seconds of silence exceed one encoder window,
 * so the clip must be cut at a pause and later chunks must keep absolute time.
 */
static int check_long_form(Fixture *fixture) {
  const size_t gap = 16000 * 2;
  const size_t count = fixture->sample_count * 3 + gap * 2;
  float *samples = calloc(count, sizeof(*samples));
  if (samples == NULL) {
    return 40;
  }
  for (size_t copy = 0; copy < 3; copy += 1) {
    memcpy(samples + copy * (fixture->sample_count + gap), fixture->samples,
           fixture->sample_count * sizeof(*samples));
  }
  uint8_t transcript[8192] = {0};
  VoiceASRSegmentV1 segments[128] = {0};
  VoiceASRResultV1 result = {0};
  const VoiceASRRequestV1 parameters = request(1);
  const uint32_t status = transcribe(
      fixture, samples, count, &parameters, transcript, sizeof(transcript) - 1,
      segments, sizeof(segments) / sizeof(segments[0]), &result);
  free(samples);
  if (status != VOICE_ASR_STATUS_OK || result.decoded_chunk_count < 2) {
    return 41;
  }
  transcript[result.transcript_length] = '\0';
  size_t occurrences = 0;
  for (const char *cursor = (const char *)transcript;
       (cursor = strstr(cursor, "ask not what your country")) != NULL;
       cursor += 1) {
    occurrences += 1;
  }
  const int64_t audio_ms = (int64_t)(count / 16);
  /* Segment joins must keep a word boundary: no "youask" or "countryand". */
  if (occurrences != 3 || strstr((const char *)transcript, "youask") != NULL ||
      check_segments(segments, result.segment_count, result.transcript_length,
                     audio_ms) != 0 ||
      segments[result.segment_count - 1].start_milliseconds <
          (int64_t)((fixture->sample_count + gap) * 2 / 16)) {
    fprintf(stderr, "Unexpected long-form transcript: %s\n", transcript);
    return 42;
  }
  return 0;
}

int main(int argument_count, char **arguments) {
  if (argument_count != 4 && argument_count != 5) {
    return 2;
  }
  double maximum_real_time_factor = 0.0;
  if (argument_count == 5) {
    char *end = NULL;
    errno = 0;
    maximum_real_time_factor = strtod(arguments[4], &end);
    if (errno != 0 || end == arguments[4] || *end != '\0' ||
        !isfinite(maximum_real_time_factor) ||
        maximum_real_time_factor <= 0.0) {
      return 2;
    }
  }
  if (voice_asr_runtime_configure_v1(2) != VOICE_ASR_STATUS_INVALID_ARGUMENT ||
      voice_asr_runtime_configure_v1(0) != VOICE_ASR_STATUS_OK) {
    return 2;
  }
  Fixture fixture = {0};
  if (asr_read_wave(arguments[3], &fixture.samples, &fixture.sample_count) !=
      0) {
    return 3;
  }
  VoiceASRContext *rejected = NULL;
  if (voice_asr_context_create_v1(arguments[1], arguments[2], 0, 0,
                                  &rejected) !=
          VOICE_ASR_STATUS_INVALID_ARGUMENT ||
      rejected != NULL ||
      voice_asr_context_create_v1(arguments[2], NULL, 0, 4, &rejected) !=
          VOICE_ASR_STATUS_MODEL_LOAD_FAILED ||
      rejected != NULL) {
    free(fixture.samples);
    return 4;
  }
  struct timespec load_start = {0};
  struct timespec load_end = {0};
  clock_gettime(CLOCK_MONOTONIC, &load_start);
  if (voice_asr_context_create_v1(arguments[1], arguments[2], 0, 8,
                                  &fixture.context) != VOICE_ASR_STATUS_OK) {
    free(fixture.samples);
    return 5;
  }
  clock_gettime(CLOCK_MONOTONIC, &load_end);
  fprintf(stdout, "load_seconds=%.6f\n", elapsed_seconds(load_start, load_end));
  static const char *const vocabulary[] = {"Kennedy", "fellow Americans"};
  int status = check_contracts(&fixture);
  if (status == 0) {
    status = check_transcript(&fixture, 0, NULL, 0, 0.0);
  }
  if (status == 0) {
    status =
        check_transcript(&fixture, 1, vocabulary, 2, maximum_real_time_factor);
  }
  if (status == 0) {
    status = check_long_form(&fixture);
  }
  voice_asr_context_destroy_v1(fixture.context);
  free(fixture.samples);
  return status;
}
