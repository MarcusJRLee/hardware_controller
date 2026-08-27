#ifndef VOICE_WHISPER_BRIDGE_H
#define VOICE_WHISPER_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VOICE_WHISPER_STATUS_OK UINT32_C(0)
#define VOICE_WHISPER_STATUS_INVALID_ARGUMENT UINT32_C(1)
#define VOICE_WHISPER_STATUS_MODEL_LOAD_FAILED UINT32_C(2)
#define VOICE_WHISPER_STATUS_INFERENCE_FAILED UINT32_C(3)
#define VOICE_WHISPER_STATUS_BUFFER_TOO_SMALL UINT32_C(4)

enum VoiceWhisperStatusV1 {
  VoiceWhisperStatusOK = VOICE_WHISPER_STATUS_OK,
  VoiceWhisperStatusInvalidArgument = VOICE_WHISPER_STATUS_INVALID_ARGUMENT,
  VoiceWhisperStatusModelLoadFailed = VOICE_WHISPER_STATUS_MODEL_LOAD_FAILED,
  VoiceWhisperStatusInferenceFailed = VOICE_WHISPER_STATUS_INFERENCE_FAILED,
  VoiceWhisperStatusBufferTooSmall = VOICE_WHISPER_STATUS_BUFFER_TOO_SMALL,
};

typedef struct VoiceWhisperContext VoiceWhisperContext;

typedef struct VoiceWhisperSegmentV1 {
  int64_t start_milliseconds;
  int64_t end_milliseconds;
  size_t text_offset;
  size_t text_length;
} VoiceWhisperSegmentV1;

typedef struct VoiceWhisperResultV1 {
  uint8_t *transcript_utf8;
  size_t transcript_capacity;
  size_t transcript_length;
  VoiceWhisperSegmentV1 *segments;
  size_t segment_capacity;
  size_t segment_count;
} VoiceWhisperResultV1;

uint32_t voice_whisper_context_create_v1(const char *model_path_utf8,
                                         uint8_t use_gpu,
                                         VoiceWhisperContext **output);

void voice_whisper_context_destroy_v1(VoiceWhisperContext *context);

/*
 * Context access is exclusive. Samples must be finite 16 kHz mono float PCM.
 * No pointer is retained after return. Output text is UTF-8 without a null
 * terminator. On BUFFER_TOO_SMALL, lengths report required capacities and no
 * caller-owned transcript or segment bytes change.
 */
uint32_t voice_whisper_transcribe_v1(VoiceWhisperContext *context,
                                     const float *samples, size_t sample_count,
                                     const char *language_utf8,
                                     uint32_t thread_count,
                                     VoiceWhisperResultV1 *output);

#ifdef __cplusplus
}
#endif

#endif
