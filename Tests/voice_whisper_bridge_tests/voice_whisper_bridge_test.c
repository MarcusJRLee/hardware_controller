#include "voice_whisper_bridge.h"

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

static uint16_t little_u16(const uint8_t *bytes) {
  return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t little_u32(const uint8_t *bytes) {
  return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
         ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static int read_wave(const char *path, float **samples, size_t *sample_count) {
  FILE *file = fopen(path, "rb");
  if (file == NULL || fseek(file, 0, SEEK_END) != 0) {
    return 1;
  }
  const long file_length = ftell(file);
  if (file_length < 44 || fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return 1;
  }
  uint8_t *bytes = malloc((size_t)file_length);
  if (bytes == NULL ||
      fread(bytes, 1, (size_t)file_length, file) != (size_t)file_length) {
    free(bytes);
    fclose(file);
    return 1;
  }
  fclose(file);
  if (memcmp(bytes, "RIFF", 4) != 0 || memcmp(bytes + 8, "WAVE", 4) != 0) {
    free(bytes);
    return 1;
  }
  const uint8_t *format = NULL;
  size_t format_length = 0;
  const uint8_t *audio = NULL;
  size_t audio_length = 0;
  size_t offset = 12;
  while (offset + 8 <= (size_t)file_length) {
    const uint32_t chunk_length = little_u32(bytes + offset + 4);
    const size_t content = offset + 8;
    if (content + chunk_length > (size_t)file_length) {
      free(bytes);
      return 1;
    }
    if (memcmp(bytes + offset, "fmt ", 4) == 0) {
      format = bytes + content;
      format_length = chunk_length;
    } else if (memcmp(bytes + offset, "data", 4) == 0) {
      audio = bytes + content;
      audio_length = chunk_length;
    }
    offset = content + chunk_length + (chunk_length & 1U);
  }
  if (format == NULL || format_length < 16 || audio == NULL ||
      little_u16(format) != 1 || little_u16(format + 2) != 1 ||
      little_u32(format + 4) != 16000 || little_u16(format + 14) != 16 ||
      audio_length == 0 || (audio_length & 1U) != 0) {
    free(bytes);
    return 1;
  }
  *sample_count = audio_length / 2;
  *samples = malloc(*sample_count * sizeof(**samples));
  if (*samples == NULL) {
    free(bytes);
    return 1;
  }
  for (size_t index = 0; index < *sample_count; index += 1) {
    const uint16_t raw = little_u16(audio + index * 2);
    (*samples)[index] = (float)(int16_t)raw / 32768.0F;
  }
  free(bytes);
  return 0;
}

int main(int argument_count, char **arguments) {
  if (argument_count != 3 && argument_count != 4) {
    return 2;
  }
  double maximum_real_time_factor = 0.0;
  if (argument_count == 4) {
    char *end = NULL;
    errno = 0;
    maximum_real_time_factor = strtod(arguments[3], &end);
    if (errno != 0 || end == arguments[3] || *end != '\0' ||
        !isfinite(maximum_real_time_factor) ||
        maximum_real_time_factor <= 0.0) {
      return 2;
    }
  }
  float *samples = NULL;
  size_t sample_count = 0;
  if (read_wave(arguments[2], &samples, &sample_count) != 0) {
    return 3;
  }
  VoiceWhisperContext *context = NULL;
  struct timespec load_start = {0};
  struct timespec load_end = {0};
  struct timespec inference_start = {0};
  struct timespec inference_end = {0};
  clock_gettime(CLOCK_MONOTONIC, &load_start);
  if (voice_whisper_context_create_v1(arguments[1], 0, &context) !=
      VOICE_WHISPER_STATUS_OK) {
    free(samples);
    return 4;
  }
  clock_gettime(CLOCK_MONOTONIC, &load_end);
  uint8_t protected_transcript = 0xA5;
  VoiceWhisperSegmentV1 protected_segment = {
      .start_milliseconds = 17,
      .end_milliseconds = 19,
      .text_offset = 23,
      .text_length = 29,
  };
  VoiceWhisperResultV1 bounded_result = {
      .transcript_utf8 = &protected_transcript,
      .transcript_capacity = 1,
      .segments = &protected_segment,
      .segment_capacity = 1,
  };
  if (voice_whisper_transcribe_v1(context, samples, sample_count, "EN", 8,
                                  &bounded_result) !=
      VOICE_WHISPER_STATUS_INVALID_ARGUMENT) {
    voice_whisper_context_destroy_v1(context);
    free(samples);
    return 11;
  }
  if (voice_whisper_transcribe_v1(context, samples, sample_count, "en", 8,
                                  &bounded_result) !=
          VOICE_WHISPER_STATUS_BUFFER_TOO_SMALL ||
      bounded_result.transcript_length <= bounded_result.transcript_capacity ||
      protected_transcript != 0xA5 ||
      protected_segment.start_milliseconds != 17 ||
      protected_segment.text_length != 29) {
    voice_whisper_context_destroy_v1(context);
    free(samples);
    return 10;
  }
  uint8_t transcript[4096] = {0};
  VoiceWhisperSegmentV1 segments[64] = {0};
  VoiceWhisperResultV1 result = {
      .transcript_utf8 = transcript,
      .transcript_capacity = sizeof(transcript),
      .segments = segments,
      .segment_capacity = sizeof(segments) / sizeof(segments[0]),
  };
  clock_gettime(CLOCK_MONOTONIC, &inference_start);
  const uint32_t status = voice_whisper_transcribe_v1(
      context, samples, sample_count, "en", 8, &result);
  clock_gettime(CLOCK_MONOTONIC, &inference_end);
  voice_whisper_context_destroy_v1(context);
  free(samples);
  if (status != VOICE_WHISPER_STATUS_OK || result.transcript_length == 0 ||
      result.segment_count == 0 ||
      result.transcript_length >= sizeof(transcript)) {
    return 5;
  }
  transcript[result.transcript_length] = '\0';
  if (strstr((const char *)transcript, "ask not what your country") == NULL) {
    fprintf(stderr, "Unexpected transcript: %s\n", transcript);
    return 6;
  }
  const double audio_seconds = (double)sample_count / 16000.0;
  const double inference_seconds =
      elapsed_seconds(inference_start, inference_end);
  fprintf(stdout,
          "load_seconds=%.6f inference_seconds=%.6f audio_seconds=%.6f "
          "real_time_factor=%.6f\n",
          elapsed_seconds(load_start, load_end), inference_seconds,
          audio_seconds, inference_seconds / audio_seconds);
  if (maximum_real_time_factor > 0.0 &&
      inference_seconds / audio_seconds > maximum_real_time_factor) {
    return 9;
  }
  size_t expected_offset = 0;
  for (size_t index = 0; index < result.segment_count; index += 1) {
    if (segments[index].text_offset != expected_offset ||
        segments[index].end_milliseconds < segments[index].start_milliseconds) {
      return 7;
    }
    expected_offset += segments[index].text_length;
  }
  return expected_offset == result.transcript_length ? 0 : 8;
}
