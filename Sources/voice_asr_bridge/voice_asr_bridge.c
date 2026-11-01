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

/*
 * Live decoding cuts at a pause of about 600 ms once a chunk holds at least
 * ten seconds. Shorter chunks lose sentence context and measurably change
 * words and casing at the cut, so ordinary dictation still decodes once and
 * only long dictation is split while recording. Silero emits one probability
 * per 32 ms frame; the two thresholds add hysteresis.
 */
#define LIVE_SPEECH_THRESHOLD 0.5F
#define LIVE_SILENCE_THRESHOLD 0.35F
#define LIVE_PAUSE_FRAMES 19
#define LIVE_FORCED_CUT_MINIMUM_PAUSE_FRAMES 5
#define LIVE_LEADING_SILENCE_FRAMES 10
#define LIVE_MINIMUM_CHUNK_MILLISECONDS 10000
#define LIVE_MAXIMUM_SAMPLES (16000U * 60U * 30U)

/* Internal accumulation bounds; callers bound their own buffers separately. */
#define MAXIMUM_INTERNAL_TRANSCRIPT_BYTES (4U * 1024U * 1024U)
#define MAXIMUM_INTERNAL_SEGMENTS 65536U

typedef struct Accumulator {
  uint8_t *transcript;
  size_t transcript_length;
  size_t transcript_capacity;
  VoiceASRSegmentV1 *segments;
  size_t segment_count;
  size_t segment_capacity;
} Accumulator;

typedef enum LivePhase { LIVE_IDLE, LIVE_ACTIVE, LIVE_FINISHED } LivePhase;

/*
 * Samples before buffer_origin are already decoded or skipped silence, so the
 * buffer holds only the current chunk and memory stays bounded by one chunk.
 */
typedef struct LiveDecode {
  LivePhase phase;
  char language[4];
  bool automatic_language;
  char **vocabulary;
  uint32_t vocabulary_count;
  float *samples;
  size_t buffer_length;
  size_t buffer_capacity;
  size_t buffer_origin;
  size_t received_samples;
  size_t chunk_start;
  size_t frame_samples;
  bool in_speech;
  bool chunk_has_speech;
  int64_t silence_start_frame;
  int64_t best_pause_frames;
  size_t best_cut_sample;
  uint32_t decoded_chunk_count;
  size_t decoded_samples;
  Accumulator result;
} LiveDecode;

struct VoiceASRContext {
  struct transcribe_model *model;
  struct transcribe_session *session;
  struct transcribe_model *speech_model;
  struct transcribe_vad_session *speech_session;
  bool supports_vocabulary;
  LiveDecode live;
};

static void live_reset(VoiceASRContext *context);

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
  live_reset(context);
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

/*
 * Decodes chunk_samples, which begin at absolute_start in the caller's
 * recording, and appends segments with absolute times.
 */
static uint32_t decode_chunk(VoiceASRContext *context,
                             const float *chunk_samples, size_t chunk_length,
                             size_t absolute_start,
                             const struct transcribe_run_params *parameters,
                             Accumulator *accumulator) {
  const Chunk chunk = {.start_sample = absolute_start,
                       .end_sample = absolute_start + chunk_length};
  const size_t minimum_samples =
      (size_t)MINIMUM_CHUNK_MILLISECONDS * SAMPLES_PER_MILLISECOND;
  const size_t decoded_samples =
      chunk_length < minimum_samples ? minimum_samples : chunk_length;
  float *padded = calloc(decoded_samples, sizeof(*padded));
  if (padded == NULL) {
    return VOICE_ASR_STATUS_INFERENCE_FAILED;
  }
  memcpy(padded, chunk_samples, chunk_length * sizeof(*padded));
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

static void free_accumulator(Accumulator *accumulator) {
  free(accumulator->transcript);
  free(accumulator->segments);
  *accumulator = (Accumulator){0};
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

static struct transcribe_run_params
run_parameters(const VoiceASRContext *context, const char *language,
               const char *const *vocabulary, uint32_t vocabulary_count) {
  struct transcribe_run_params parameters;
  transcribe_run_params_init(&parameters);
  parameters.timestamps = TRANSCRIBE_TIMESTAMPS_SEGMENT;
  parameters.language = language;
  if (context->supports_vocabulary && vocabulary_count > 0) {
    parameters.vocabulary = vocabulary;
    parameters.n_vocabulary = (int32_t)vocabulary_count;
  }
  return parameters;
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
  live_reset(context);
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
    status =
        decode_chunk(context, samples + chunks[index].start_sample,
                     chunks[index].end_sample - chunks[index].start_sample,
                     chunks[index].start_sample, &parameters, &accumulator);
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
  free_accumulator(&accumulator);
  return status;
}

static void live_reset(VoiceASRContext *context) {
  LiveDecode *live = &context->live;
  for (uint32_t index = 0; index < live->vocabulary_count; index += 1) {
    free(live->vocabulary[index]);
  }
  free(live->vocabulary);
  free(live->samples);
  free_accumulator(&live->result);
  *live = (LiveDecode){0};
  if (context->speech_session != NULL) {
    transcribe_vad_stream_reset(context->speech_session);
  }
}

uint32_t voice_asr_live_begin_v1(VoiceASRContext *context,
                                 const VoiceASRRequestV1 *request) {
  if (context == NULL || !valid_request(request) ||
      request->detect_speech != 1) {
    return VOICE_ASR_STATUS_INVALID_ARGUMENT;
  }
  live_reset(context);
  if (context->speech_session == NULL) {
    return VOICE_ASR_STATUS_SPEECH_DETECTION_UNAVAILABLE;
  }
  struct transcribe_vad_info info;
  transcribe_vad_info_init(&info);
  if (transcribe_vad_get_info(context->speech_model, &info) != TRANSCRIBE_OK ||
      info.frame_samples <= 0) {
    return VOICE_ASR_STATUS_INFERENCE_FAILED;
  }
  LiveDecode *live = &context->live;
  live->frame_samples = (size_t)info.frame_samples;
  live->automatic_language = strcmp(request->language_utf8, "auto") == 0;
  if (!live->automatic_language) {
    memcpy(live->language, request->language_utf8,
           strlen(request->language_utf8) + 1);
  }
  if (request->vocabulary_count > 0) {
    live->vocabulary =
        calloc(request->vocabulary_count, sizeof(*live->vocabulary));
    if (live->vocabulary == NULL) {
      return VOICE_ASR_STATUS_INFERENCE_FAILED;
    }
    for (uint32_t index = 0; index < request->vocabulary_count; index += 1) {
      live->vocabulary[index] = strdup(request->vocabulary_utf8[index]);
      live->vocabulary_count = index + 1;
      if (live->vocabulary[index] == NULL) {
        live_reset(context);
        return VOICE_ASR_STATUS_INFERENCE_FAILED;
      }
    }
  }
  live->phase = LIVE_ACTIVE;
  return VOICE_ASR_STATUS_OK;
}

static uint32_t live_decode_until(VoiceASRContext *context, size_t cut) {
  LiveDecode *live = &context->live;
  if (live->chunk_has_speech && cut > live->chunk_start) {
    const struct transcribe_run_params parameters = run_parameters(
        context, live->automatic_language ? NULL : live->language,
        (const char *const *)live->vocabulary, live->vocabulary_count);
    const uint32_t status = decode_chunk(
        context, live->samples + (live->chunk_start - live->buffer_origin),
        cut - live->chunk_start, live->chunk_start, &parameters, &live->result);
    if (status != VOICE_ASR_STATUS_OK) {
      return status;
    }
    live->decoded_chunk_count += 1;
    live->decoded_samples += cut - live->chunk_start;
  }
  live->chunk_start = cut;
  live->chunk_has_speech = live->in_speech;
  live->best_pause_frames = 0;
  live->best_cut_sample = 0;
  return VOICE_ASR_STATUS_OK;
}

/* Releases samples before the chunk start so memory holds one chunk. */
static void live_compact(LiveDecode *live) {
  const size_t discard = live->chunk_start - live->buffer_origin;
  if (discard == 0) {
    return;
  }
  memmove(live->samples, live->samples + discard,
          (live->buffer_length - discard) * sizeof(*live->samples));
  live->buffer_length -= discard;
  live->buffer_origin = live->chunk_start;
}

static uint32_t live_classify_frames(VoiceASRContext *context) {
  LiveDecode *live = &context->live;
  struct transcribe_vad_result summary;
  transcribe_vad_result_init(&summary);
  if (transcribe_vad_get_result(context->speech_session, &summary) !=
          TRANSCRIBE_OK ||
      summary.n_probs < 0 || summary.first_frame < 0) {
    return VOICE_ASR_STATUS_INFERENCE_FAILED;
  }
  const float *probabilities = transcribe_vad_probs(context->speech_session);
  if (summary.n_probs > 0 && probabilities == NULL) {
    return VOICE_ASR_STATUS_INFERENCE_FAILED;
  }
  const size_t minimum_chunk =
      (size_t)LIVE_MINIMUM_CHUNK_MILLISECONDS * SAMPLES_PER_MILLISECOND;
  const size_t maximum_chunk =
      (size_t)MAXIMUM_CHUNK_MILLISECONDS * SAMPLES_PER_MILLISECOND;
  for (int32_t index = 0; index < summary.n_probs; index += 1) {
    const int64_t frame = summary.first_frame + index;
    /* Flushed final frames may extend past the received samples. */
    size_t frame_end = (size_t)(frame + 1) * live->frame_samples;
    frame_end =
        frame_end > live->received_samples ? live->received_samples : frame_end;
    const float probability = probabilities[index];
    if (probability >= LIVE_SPEECH_THRESHOLD) {
      live->in_speech = true;
      live->chunk_has_speech = true;
    } else if (live->in_speech && probability < LIVE_SILENCE_THRESHOLD) {
      live->in_speech = false;
      live->silence_start_frame = frame;
    }
    if (!live->chunk_has_speech) {
      /* Drop leading silence beyond a short pad, as batch detection does. */
      const int64_t keep_frame = frame + 1 - LIVE_LEADING_SILENCE_FRAMES;
      const size_t keep =
          keep_frame > 0 ? (size_t)keep_frame * live->frame_samples : 0;
      if (keep > live->chunk_start && keep <= live->received_samples) {
        live->chunk_start = keep;
      }
      continue;
    }
    if (!live->in_speech) {
      const int64_t pause_frames = frame - live->silence_start_frame + 1;
      const size_t cut =
          (size_t)(live->silence_start_frame + pause_frames / 2) *
          live->frame_samples;
      if (pause_frames > live->best_pause_frames && cut > live->chunk_start) {
        live->best_pause_frames = pause_frames;
        live->best_cut_sample = cut;
      }
      if (pause_frames >= LIVE_PAUSE_FRAMES && cut > live->chunk_start &&
          cut - live->chunk_start >= minimum_chunk) {
        const uint32_t status = live_decode_until(context, cut);
        if (status != VOICE_ASR_STATUS_OK) {
          return status;
        }
        continue;
      }
    }
    if (frame_end - live->chunk_start >= maximum_chunk) {
      const size_t cut =
          live->best_pause_frames >= LIVE_FORCED_CUT_MINIMUM_PAUSE_FRAMES
              ? live->best_cut_sample
              : frame_end;
      const uint32_t status = live_decode_until(context, cut);
      if (status != VOICE_ASR_STATUS_OK) {
        return status;
      }
    }
  }
  live_compact(live);
  return VOICE_ASR_STATUS_OK;
}

static void write_progress(const LiveDecode *live,
                           VoiceASRLiveProgressV1 *progress) {
  if (progress != NULL) {
    *progress = (VoiceASRLiveProgressV1){
        .received_samples = live->received_samples,
        .decoded_samples = live->decoded_samples,
        .decoded_chunk_count = live->decoded_chunk_count,
    };
  }
}

uint32_t voice_asr_live_feed_v1(VoiceASRContext *context, const float *samples,
                                size_t sample_count,
                                VoiceASRLiveProgressV1 *progress) {
  if (context == NULL || context->live.phase != LIVE_ACTIVE) {
    return VOICE_ASR_STATUS_LIVE_STATE_INVALID;
  }
  LiveDecode *live = &context->live;
  if (sample_count == 0) {
    write_progress(live, progress);
    return VOICE_ASR_STATUS_OK;
  }
  if (!valid_samples(samples, sample_count)) {
    live_reset(context);
    return VOICE_ASR_STATUS_INVALID_ARGUMENT;
  }
  if (sample_count > LIVE_MAXIMUM_SAMPLES - live->received_samples) {
    live_reset(context);
    return VOICE_ASR_STATUS_LIVE_LIMIT_EXCEEDED;
  }
  const size_t required = live->buffer_length + sample_count;
  if (required > live->buffer_capacity) {
    size_t capacity =
        live->buffer_capacity == 0 ? 16000 * 8 : live->buffer_capacity;
    while (capacity < required) {
      capacity *= 2;
    }
    float *grown = realloc(live->samples, capacity * sizeof(*grown));
    if (grown == NULL) {
      live_reset(context);
      return VOICE_ASR_STATUS_INFERENCE_FAILED;
    }
    live->samples = grown;
    live->buffer_capacity = capacity;
  }
  memcpy(live->samples + live->buffer_length, samples,
         sample_count * sizeof(*samples));
  live->buffer_length = required;
  live->received_samples += sample_count;
  uint32_t status =
      transcribe_vad_stream_feed(context->speech_session, samples,
                                 (int)sample_count) == TRANSCRIBE_OK
          ? live_classify_frames(context)
          : VOICE_ASR_STATUS_INFERENCE_FAILED;
  if (status != VOICE_ASR_STATUS_OK) {
    live_reset(context);
    return status;
  }
  write_progress(live, progress);
  return VOICE_ASR_STATUS_OK;
}

uint32_t voice_asr_live_finish_v1(VoiceASRContext *context,
                                  VoiceASRResultV1 *output) {
  if (context == NULL || !valid_output(output)) {
    return VOICE_ASR_STATUS_INVALID_ARGUMENT;
  }
  LiveDecode *live = &context->live;
  if (live->phase == LIVE_IDLE) {
    return VOICE_ASR_STATUS_LIVE_STATE_INVALID;
  }
  uint32_t status = VOICE_ASR_STATUS_OK;
  if (live->phase == LIVE_ACTIVE) {
    status =
        transcribe_vad_stream_flush(context->speech_session) == TRANSCRIBE_OK
            ? live_classify_frames(context)
            : VOICE_ASR_STATUS_INFERENCE_FAILED;
    if (status == VOICE_ASR_STATUS_OK) {
      status = live_decode_until(context, live->received_samples);
    }
    live->phase = LIVE_FINISHED;
  }
  if (status == VOICE_ASR_STATUS_OK && live->decoded_chunk_count == 0) {
    status = VOICE_ASR_STATUS_NO_SPEECH;
  }
  output->transcript_length = 0;
  output->segment_count = 0;
  output->decoded_chunk_count = 0;
  if (status == VOICE_ASR_STATUS_OK) {
    status = copy_result(&live->result, output);
    if (status == VOICE_ASR_STATUS_OK) {
      output->decoded_chunk_count = live->decoded_chunk_count;
    }
  }
  if (status != VOICE_ASR_STATUS_BUFFER_TOO_SMALL) {
    if (status != VOICE_ASR_STATUS_OK) {
      output->transcript_length = 0;
      output->segment_count = 0;
    }
    live_reset(context);
  }
  return status;
}

void voice_asr_live_cancel_v1(VoiceASRContext *context) {
  if (context != NULL) {
    live_reset(context);
  }
}
