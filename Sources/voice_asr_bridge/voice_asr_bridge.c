#include "voice_asr_bridge.h"

#include <ctype.h>
#include <limits.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include <CTranscribe/transcribe.h>
#include <CTranscribe/vad.h>

#define SAMPLES_PER_MILLISECOND 16

/*
 * Whisper-family encoders see 30-second windows. Chunks stay below that so a
 * pause, not the encoder boundary, decides where speech is cut.
 */
#define MAXIMUM_CHUNK_MILLISECONDS 28000

/*
 * Transducer models such as Parakeet lose accuracy on very short input, so
 * short chunks are padded with trailing silence before decoding.
 */
#define MINIMUM_CHUNK_MILLISECONDS 1500

/* Internal accumulation bounds; callers bound their own buffers separately. */
#define MAXIMUM_INTERNAL_TRANSCRIPT_BYTES (4U * 1024U * 1024U)
#define MAXIMUM_INTERNAL_SEGMENTS 65536U

struct VoiceASRContext {
  struct transcribe_model *model;
  struct transcribe_session *session;
  struct transcribe_model *speech_model;
  struct transcribe_vad_session *speech_session;
  bool supports_vocabulary;
};

typedef struct Accumulator {
  uint8_t *transcript;
  size_t transcript_length;
  size_t transcript_capacity;
  VoiceASRSegmentV1 *segments;
  size_t segment_count;
  size_t segment_capacity;
} Accumulator;

typedef struct Chunk {
  size_t start_sample;
  size_t end_sample;
} Chunk;

uint32_t voice_asr_runtime_configure_v1(uint8_t emit_diagnostics) {
  if (emit_diagnostics > 1) {
    return VOICE_ASR_STATUS_INVALID_ARGUMENT;
  }
  if (emit_diagnostics == 0) {
    transcribe_log_set(NULL, NULL);
  }
  return VOICE_ASR_STATUS_OK;
}

static void destroy_runtime(VoiceASRContext *context) {
  transcribe_vad_session_free(context->speech_session);
  transcribe_model_free(context->speech_model);
  transcribe_session_free(context->session);
  transcribe_model_free(context->model);
}

static bool valid_path(const char *path) {
  return path != NULL && path[0] != '\0';
}

uint32_t voice_asr_context_create_v1(const char *model_path_utf8,
                                     const char *speech_model_path_utf8,
                                     uint8_t use_gpu, uint32_t thread_count,
                                     VoiceASRContext **output) {
  if (output == NULL) {
    return VOICE_ASR_STATUS_INVALID_ARGUMENT;
  }
  *output = NULL;
  if (!valid_path(model_path_utf8) ||
      (speech_model_path_utf8 != NULL && !valid_path(speech_model_path_utf8)) ||
      use_gpu > 1 || thread_count == 0 || thread_count > 16) {
    return VOICE_ASR_STATUS_INVALID_ARGUMENT;
  }
  VoiceASRContext *context = calloc(1, sizeof(*context));
  if (context == NULL) {
    return VOICE_ASR_STATUS_MODEL_LOAD_FAILED;
  }

  struct transcribe_model_load_params load;
  transcribe_model_load_params_init(&load);
  load.backend =
      use_gpu == 1 ? TRANSCRIBE_BACKEND_AUTO : TRANSCRIBE_BACKEND_CPU;
  struct transcribe_session_params session;
  transcribe_session_params_init(&session);
  session.n_threads = (int)thread_count;
  if (transcribe_model_load_file(model_path_utf8, &load, &context->model) !=
          TRANSCRIBE_OK ||
      (transcribe_model_roles(context->model) & TRANSCRIBE_ROLE_ASR) == 0 ||
      transcribe_session_init(context->model, &session, &context->session) !=
          TRANSCRIBE_OK) {
    destroy_runtime(context);
    free(context);
    return VOICE_ASR_STATUS_MODEL_LOAD_FAILED;
  }
  context->supports_vocabulary =
      transcribe_model_supports(context->model, TRANSCRIBE_FEATURE_VOCABULARY);

  if (speech_model_path_utf8 != NULL) {
    /* Speech detection is cheap and runs on the CPU in every configuration. */
    struct transcribe_model_load_params speech_load;
    transcribe_model_load_params_init(&speech_load);
    speech_load.backend = TRANSCRIBE_BACKEND_CPU;
    struct transcribe_vad_info info;
    transcribe_vad_info_init(&info);
    if (transcribe_model_load_file(speech_model_path_utf8, &speech_load,
                                   &context->speech_model) != TRANSCRIBE_OK ||
        transcribe_vad_get_info(context->speech_model, &info) !=
            TRANSCRIBE_OK ||
        info.sample_rate != 16000 ||
        transcribe_vad_session_init(context->speech_model, NULL,
                                    &context->speech_session) !=
            TRANSCRIBE_OK) {
      destroy_runtime(context);
      free(context);
      return VOICE_ASR_STATUS_MODEL_LOAD_FAILED;
    }
  }
  *output = context;
  return VOICE_ASR_STATUS_OK;
}

void voice_asr_context_destroy_v1(VoiceASRContext *context) {
  if (context == NULL) {
    return;
  }
  destroy_runtime(context);
  free(context);
}

uint32_t voice_asr_context_info_v1(const VoiceASRContext *context,
                                   VoiceASRContextInfoV1 *output) {
  if (context == NULL || output == NULL) {
    return VOICE_ASR_STATUS_INVALID_ARGUMENT;
  }
  *output = (VoiceASRContextInfoV1){
      .supports_vocabulary = context->supports_vocabulary ? 1 : 0,
      .supports_speech_detection = context->speech_session != NULL ? 1 : 0,
  };
  return VOICE_ASR_STATUS_OK;
}

static bool valid_samples(const float *samples, size_t sample_count) {
  if (samples == NULL || sample_count == 0 || sample_count > INT32_MAX) {
    return false;
  }
  for (size_t index = 0; index < sample_count; index += 1) {
    if (!isfinite(samples[index])) {
      return false;
    }
  }
  return true;
}

static bool valid_language(const char *language_utf8) {
  if (language_utf8 == NULL) {
    return false;
  }
  if (strcmp(language_utf8, "auto") == 0) {
    return true;
  }
  const size_t length = strlen(language_utf8);
  if (length < 2 || length > 3) {
    return false;
  }
  for (size_t index = 0; index < length; index += 1) {
    if (language_utf8[index] < 'a' || language_utf8[index] > 'z') {
      return false;
    }
  }
  return true;
}

static bool valid_request(const VoiceASRRequestV1 *request) {
  if (request == NULL || !valid_language(request->language_utf8) ||
      request->detect_speech > 1 ||
      request->vocabulary_count > VOICE_ASR_MAXIMUM_VOCABULARY_TERMS ||
      (request->vocabulary_count > 0 && request->vocabulary_utf8 == NULL)) {
    return false;
  }
  for (size_t index = 0; index < sizeof(request->reserved); index += 1) {
    if (request->reserved[index] != 0) {
      return false;
    }
  }
  for (uint32_t index = 0; index < request->vocabulary_count; index += 1) {
    const char *term = request->vocabulary_utf8[index];
    if (term == NULL || term[0] == '\0') {
      return false;
    }
  }
  return true;
}

static bool valid_output(const VoiceASRResultV1 *output) {
  return output != NULL &&
         (output->transcript_capacity == 0 ||
          output->transcript_utf8 != NULL) &&
         (output->segment_capacity == 0 || output->segments != NULL);
}

/*
 * Detects speech and merges neighbouring segments into chunks no longer than
 * the encoder window. Silence between merged segments stays in its chunk so
 * that model timestamps remain contiguous within the chunk.
 */
static uint32_t plan_speech_chunks(VoiceASRContext *context,
                                   const float *samples, size_t sample_count,
                                   Chunk **chunks, size_t *chunk_count) {
  *chunks = NULL;
  *chunk_count = 0;
  struct transcribe_vad_params parameters;
  transcribe_vad_params_init(&parameters);
  parameters.min_silence_ms = 300;
  parameters.speech_pad_ms = 200;
  parameters.max_speech_ms = MAXIMUM_CHUNK_MILLISECONDS;
  if (transcribe_vad_run(context->speech_session, samples, (int)sample_count,
                         &parameters) != TRANSCRIBE_OK) {
    return VOICE_ASR_STATUS_INFERENCE_FAILED;
  }
  struct transcribe_vad_result summary;
  transcribe_vad_result_init(&summary);
  if (transcribe_vad_get_result(context->speech_session, &summary) !=
          TRANSCRIBE_OK ||
      summary.n_segments < 0) {
    return VOICE_ASR_STATUS_INFERENCE_FAILED;
  }
  if (summary.n_segments == 0) {
    return VOICE_ASR_STATUS_NO_SPEECH;
  }
  Chunk *planned = calloc((size_t)summary.n_segments, sizeof(*planned));
  if (planned == NULL) {
    return VOICE_ASR_STATUS_INFERENCE_FAILED;
  }
  const size_t maximum_chunk_samples =
      (size_t)MAXIMUM_CHUNK_MILLISECONDS * SAMPLES_PER_MILLISECOND;
  size_t count = 0;
  for (int index = 0; index < summary.n_segments; index += 1) {
    struct transcribe_vad_segment segment;
    transcribe_vad_segment_init(&segment);
    if (transcribe_vad_get_segment(context->speech_session, index, &segment) !=
            TRANSCRIBE_OK ||
        segment.start_sample < 0 ||
        segment.end_sample <= segment.start_sample ||
        (size_t)segment.end_sample > sample_count ||
        (count > 0 &&
         (size_t)segment.start_sample < planned[count - 1].end_sample)) {
      free(planned);
      return VOICE_ASR_STATUS_INFERENCE_FAILED;
    }
    const size_t start = (size_t)segment.start_sample;
    const size_t end = (size_t)segment.end_sample;
    if (count > 0 &&
        end - planned[count - 1].start_sample <= maximum_chunk_samples) {
      planned[count - 1].end_sample = end;
    } else {
      planned[count] = (Chunk){.start_sample = start, .end_sample = end};
      count += 1;
    }
  }
  *chunks = planned;
  *chunk_count = count;
  return VOICE_ASR_STATUS_OK;
}

static bool append_bytes(Accumulator *accumulator, const char *text,
                         size_t length) {
  if (length >
      MAXIMUM_INTERNAL_TRANSCRIPT_BYTES - accumulator->transcript_length) {
    return false;
  }
  const size_t required = accumulator->transcript_length + length;
  if (required > accumulator->transcript_capacity) {
    size_t capacity = accumulator->transcript_capacity == 0
                          ? 4096
                          : accumulator->transcript_capacity;
    while (capacity < required) {
      capacity *= 2;
    }
    uint8_t *grown = realloc(accumulator->transcript, capacity);
    if (grown == NULL) {
      return false;
    }
    accumulator->transcript = grown;
    accumulator->transcript_capacity = capacity;
  }
  if (length > 0) {
    memcpy(accumulator->transcript + accumulator->transcript_length, text,
           length);
  }
  accumulator->transcript_length = required;
  return true;
}

static bool append_segment(Accumulator *accumulator,
                           VoiceASRSegmentV1 segment) {
  if (accumulator->segment_count >= MAXIMUM_INTERNAL_SEGMENTS) {
    return false;
  }
  if (accumulator->segment_count == accumulator->segment_capacity) {
    const size_t capacity = accumulator->segment_capacity == 0
                                ? 64
                                : accumulator->segment_capacity * 2;
    VoiceASRSegmentV1 *grown =
        realloc(accumulator->segments, capacity * sizeof(*grown));
    if (grown == NULL) {
      return false;
    }
    accumulator->segments = grown;
    accumulator->segment_capacity = capacity;
  }
  accumulator->segments[accumulator->segment_count] = segment;
  accumulator->segment_count += 1;
  return true;
}

static uint32_t decode_chunk(VoiceASRContext *context, const float *samples,
                             Chunk chunk,
                             const struct transcribe_run_params *parameters,
                             Accumulator *accumulator) {
  const size_t minimum_samples =
      (size_t)MINIMUM_CHUNK_MILLISECONDS * SAMPLES_PER_MILLISECOND;
  const size_t chunk_samples = chunk.end_sample - chunk.start_sample;
  const size_t decoded_samples =
      chunk_samples < minimum_samples ? minimum_samples : chunk_samples;
  float *padded = calloc(decoded_samples, sizeof(*padded));
  if (padded == NULL) {
    return VOICE_ASR_STATUS_INFERENCE_FAILED;
  }
  memcpy(padded, samples + chunk.start_sample, chunk_samples * sizeof(*padded));
  const transcribe_status status = transcribe_run(
      context->session, padded, (int)decoded_samples, parameters);
  free(padded);
  if (status == TRANSCRIBE_ERR_OUTPUT_TRUNCATED ||
      status == TRANSCRIBE_ERR_OUTPUT_REPETITION) {
    return VOICE_ASR_STATUS_INCOMPLETE_TRANSCRIPT;
  }
  if (status != TRANSCRIBE_OK) {
    return VOICE_ASR_STATUS_INFERENCE_FAILED;
  }
  const int segment_count = transcribe_n_segments(context->session);
  if (segment_count < 0) {
    return VOICE_ASR_STATUS_INFERENCE_FAILED;
  }
  const int64_t offset_milliseconds =
      (int64_t)(chunk.start_sample / SAMPLES_PER_MILLISECOND);
  const int64_t chunk_end_milliseconds =
      (int64_t)(chunk.end_sample / SAMPLES_PER_MILLISECOND);
  for (int index = 0; index < segment_count; index += 1) {
    struct transcribe_segment segment;
    transcribe_segment_init(&segment);
    if (transcribe_get_segment(context->session, index, &segment) !=
            TRANSCRIBE_OK ||
        segment.text == NULL || segment.t0_ms < 0 ||
        segment.t1_ms < segment.t0_ms) {
      return VOICE_ASR_STATUS_INFERENCE_FAILED;
    }
    /* Padding may extend model time past the real chunk; clamp to input. */
    int64_t start = offset_milliseconds + segment.t0_ms;
    int64_t end = offset_milliseconds + segment.t1_ms;
    start = start > chunk_end_milliseconds ? chunk_end_milliseconds : start;
    end = end > chunk_end_milliseconds ? chunk_end_milliseconds : end;
    const size_t length = strlen(segment.text);
    const size_t text_offset = accumulator->transcript_length;
    /*
     * Runtime segments do not carry their separating whitespace. The space is
     * owned by the following segment so that offsets stay contiguous.
     */
    const bool needs_separator =
        accumulator->transcript_length > 0 && length > 0 &&
        !isspace(accumulator->transcript[accumulator->transcript_length - 1]) &&
        !isspace((unsigned char)segment.text[0]);
    if ((needs_separator && !append_bytes(accumulator, " ", 1)) ||
        !append_bytes(accumulator, segment.text, length) ||
        !append_segment(accumulator,
                        (VoiceASRSegmentV1){
                            .start_milliseconds = start,
                            .end_milliseconds = end,
                            .text_offset = text_offset,
                            .text_length = length + (needs_separator ? 1 : 0),
                        })) {
      return VOICE_ASR_STATUS_INFERENCE_FAILED;
    }
  }
  return VOICE_ASR_STATUS_OK;
}

static uint32_t copy_result(const Accumulator *accumulator,
                            VoiceASRResultV1 *output) {
  output->transcript_length = accumulator->transcript_length;
  output->segment_count = accumulator->segment_count;
  if (output->transcript_capacity < accumulator->transcript_length ||
      output->segment_capacity < accumulator->segment_count) {
    return VOICE_ASR_STATUS_BUFFER_TOO_SMALL;
  }
  if (accumulator->transcript_length > 0) {
    memcpy(output->transcript_utf8, accumulator->transcript,
           accumulator->transcript_length);
  }
  if (accumulator->segment_count > 0) {
    memcpy(output->segments, accumulator->segments,
           accumulator->segment_count * sizeof(*accumulator->segments));
  }
  return VOICE_ASR_STATUS_OK;
}

uint32_t voice_asr_transcribe_v1(VoiceASRContext *context, const float *samples,
                                 size_t sample_count,
                                 const VoiceASRRequestV1 *request,
                                 VoiceASRResultV1 *output) {
  if (context == NULL || context->session == NULL ||
      !valid_samples(samples, sample_count) || !valid_request(request) ||
      !valid_output(output)) {
    return VOICE_ASR_STATUS_INVALID_ARGUMENT;
  }
  output->transcript_length = 0;
  output->segment_count = 0;
  output->decoded_chunk_count = 0;
  if (request->detect_speech == 1 && context->speech_session == NULL) {
    return VOICE_ASR_STATUS_SPEECH_DETECTION_UNAVAILABLE;
  }

  Chunk whole_clip = {.start_sample = 0, .end_sample = sample_count};
  Chunk *chunks = &whole_clip;
  size_t chunk_count = 1;
  Chunk *planned = NULL;
  if (request->detect_speech == 1) {
    const uint32_t status = plan_speech_chunks(context, samples, sample_count,
                                               &planned, &chunk_count);
    if (status != VOICE_ASR_STATUS_OK) {
      return status;
    }
    chunks = planned;
  }

  struct transcribe_run_params parameters;
  transcribe_run_params_init(&parameters);
  parameters.timestamps = TRANSCRIBE_TIMESTAMPS_SEGMENT;
  parameters.language = strcmp(request->language_utf8, "auto") == 0
                            ? NULL
                            : request->language_utf8;
  if (context->supports_vocabulary && request->vocabulary_count > 0) {
    parameters.vocabulary = request->vocabulary_utf8;
    parameters.n_vocabulary = (int32_t)request->vocabulary_count;
  }

  Accumulator accumulator = {0};
  uint32_t status = VOICE_ASR_STATUS_OK;
  for (size_t index = 0; index < chunk_count && status == VOICE_ASR_STATUS_OK;
       index += 1) {
    status = decode_chunk(context, samples, chunks[index], &parameters,
                          &accumulator);
  }
  free(planned);
  if (status == VOICE_ASR_STATUS_OK) {
    output->decoded_chunk_count = (uint32_t)chunk_count;
    status = copy_result(&accumulator, output);
  }
  if (status != VOICE_ASR_STATUS_OK &&
      status != VOICE_ASR_STATUS_BUFFER_TOO_SMALL) {
    output->transcript_length = 0;
    output->segment_count = 0;
    output->decoded_chunk_count = 0;
  }
  free(accumulator.transcript);
  free(accumulator.segments);
  return status;
}
