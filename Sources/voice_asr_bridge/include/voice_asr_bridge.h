#ifndef VOICE_ASR_BRIDGE_H
#define VOICE_ASR_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VOICE_ASR_STATUS_OK UINT32_C(0)
#define VOICE_ASR_STATUS_INVALID_ARGUMENT UINT32_C(1)
#define VOICE_ASR_STATUS_MODEL_LOAD_FAILED UINT32_C(2)
#define VOICE_ASR_STATUS_INFERENCE_FAILED UINT32_C(3)
#define VOICE_ASR_STATUS_BUFFER_TOO_SMALL UINT32_C(4)
#define VOICE_ASR_STATUS_NO_SPEECH UINT32_C(5)
#define VOICE_ASR_STATUS_INCOMPLETE_TRANSCRIPT UINT32_C(6)
#define VOICE_ASR_STATUS_SPEECH_DETECTION_UNAVAILABLE UINT32_C(7)

enum VoiceASRStatusV1 {
  VoiceASRStatusOK = VOICE_ASR_STATUS_OK,
  VoiceASRStatusInvalidArgument = VOICE_ASR_STATUS_INVALID_ARGUMENT,
  VoiceASRStatusModelLoadFailed = VOICE_ASR_STATUS_MODEL_LOAD_FAILED,
  VoiceASRStatusInferenceFailed = VOICE_ASR_STATUS_INFERENCE_FAILED,
  VoiceASRStatusBufferTooSmall = VOICE_ASR_STATUS_BUFFER_TOO_SMALL,
  VoiceASRStatusNoSpeech = VOICE_ASR_STATUS_NO_SPEECH,
  VoiceASRStatusIncompleteTranscript = VOICE_ASR_STATUS_INCOMPLETE_TRANSCRIPT,
  VoiceASRStatusSpeechDetectionUnavailable =
      VOICE_ASR_STATUS_SPEECH_DETECTION_UNAVAILABLE,
};

/* The most vocabulary terms one request may carry. */
#define VOICE_ASR_MAXIMUM_VOCABULARY_TERMS UINT32_C(64)

typedef struct VoiceASRContext VoiceASRContext;

/*
 * Configures process-wide runtime diagnostics once, before the first context
 * is created. 0 discards every runtime and kernel log line; 1 keeps them on
 * standard error for development builds.
 */
uint32_t voice_asr_runtime_configure_v1(uint8_t emit_diagnostics);

typedef struct VoiceASRContextInfoV1 {
  /* 1 when the loaded model applies request vocabulary to recognition. */
  uint8_t supports_vocabulary;
  /* 1 when a speech-detection model was loaded beside the ASR model. */
  uint8_t supports_speech_detection;
  uint8_t reserved[6];
} VoiceASRContextInfoV1;

typedef struct VoiceASRRequestV1 {
  /* "auto" or a lowercase ISO 639 primary subtag of two or three letters. */
  const char *language_utf8;
  /* Ordered, null-terminated UTF-8 terms; NULL when vocabulary_count is 0. */
  const char *const *vocabulary_utf8;
  uint32_t vocabulary_count;
  /*
   * 1 decodes only detected speech, cut at pauses into bounded chunks. 0
   * decodes the whole clip once.
   */
  uint8_t detect_speech;
  uint8_t reserved[3];
} VoiceASRRequestV1;

typedef struct VoiceASRSegmentV1 {
  int64_t start_milliseconds;
  int64_t end_milliseconds;
  size_t text_offset;
  size_t text_length;
} VoiceASRSegmentV1;

typedef struct VoiceASRResultV1 {
  uint8_t *transcript_utf8;
  size_t transcript_capacity;
  size_t transcript_length;
  VoiceASRSegmentV1 *segments;
  size_t segment_capacity;
  size_t segment_count;
  /* Audio chunks decoded by the runtime; 0 when no speech was detected. */
  uint32_t decoded_chunk_count;
  uint32_t reserved;
} VoiceASRResultV1;

/*
 * Loads one transcribe.cpp ASR model and, when speech_model_path_utf8 is not
 * NULL, one speech-detection model. Models are memory-mapped, so neither file
 * may be rewritten in place while the context exists. thread_count is 1–16.
 */
uint32_t voice_asr_context_create_v1(const char *model_path_utf8,
                                     const char *speech_model_path_utf8,
                                     uint8_t use_gpu, uint32_t thread_count,
                                     VoiceASRContext **output);

void voice_asr_context_destroy_v1(VoiceASRContext *context);

uint32_t voice_asr_context_info_v1(const VoiceASRContext *context,
                                   VoiceASRContextInfoV1 *output);

/*
 * Context access is exclusive. Samples must be finite 16 kHz mono float PCM.
 * No pointer is retained after return. Output text is UTF-8 without a null
 * terminator, and segment times are relative to the first input sample. On
 * BUFFER_TOO_SMALL, lengths report required capacities and no caller-owned
 * transcript or segment bytes change. NO_SPEECH and INCOMPLETE_TRANSCRIPT
 * report zero lengths so that no partial text can be delivered.
 */
uint32_t voice_asr_transcribe_v1(VoiceASRContext *context, const float *samples,
                                 size_t sample_count,
                                 const VoiceASRRequestV1 *request,
                                 VoiceASRResultV1 *output);

#ifdef __cplusplus
}
#endif

#endif
