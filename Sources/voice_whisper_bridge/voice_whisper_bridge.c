#include "voice_whisper_bridge.h"

#include <limits.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include <whisper/whisper.h>

struct VoiceWhisperContext {
  struct whisper_context *runtime;
};

uint32_t voice_whisper_context_create_v1(const char *model_path_utf8,
                                         uint8_t use_gpu,
                                         VoiceWhisperContext **output) {
  if (model_path_utf8 == NULL || model_path_utf8[0] == '\0' || output == NULL ||
      use_gpu > 1) {
    return VOICE_WHISPER_STATUS_INVALID_ARGUMENT;
  }
  *output = NULL;
  struct whisper_context_params parameters = whisper_context_default_params();
  parameters.use_gpu = use_gpu == 1;
  parameters.flash_attn = use_gpu == 1;
  struct whisper_context *runtime =
      whisper_init_from_file_with_params(model_path_utf8, parameters);
  if (runtime == NULL) {
    return VOICE_WHISPER_STATUS_MODEL_LOAD_FAILED;
  }
  VoiceWhisperContext *context = calloc(1, sizeof(*context));
  if (context == NULL) {
    whisper_free(runtime);
    return VOICE_WHISPER_STATUS_MODEL_LOAD_FAILED;
  }
  context->runtime = runtime;
  *output = context;
  return VOICE_WHISPER_STATUS_OK;
}

void voice_whisper_context_destroy_v1(VoiceWhisperContext *context) {
  if (context == NULL) {
    return;
  }
  whisper_free(context->runtime);
  context->runtime = NULL;
  free(context);
}

static bool valid_output(const VoiceWhisperResultV1 *output) {
  return output != NULL &&
         (output->transcript_capacity == 0 ||
          output->transcript_utf8 != NULL) &&
         (output->segment_capacity == 0 || output->segments != NULL);
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
  const size_t length = strlen(language_utf8);
  if (strcmp(language_utf8, "auto") == 0) {
    return true;
  }
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

uint32_t voice_whisper_transcribe_v1(VoiceWhisperContext *context,
                                     const float *samples, size_t sample_count,
                                     const char *language_utf8,
                                     uint32_t thread_count,
                                     VoiceWhisperResultV1 *output) {
  if (context == NULL || context->runtime == NULL ||
      !valid_samples(samples, sample_count) || !valid_language(language_utf8) ||
      thread_count == 0 || thread_count > 16 || !valid_output(output)) {
    return VOICE_WHISPER_STATUS_INVALID_ARGUMENT;
  }
  output->transcript_length = 0;
  output->segment_count = 0;

  struct whisper_full_params parameters =
      whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  parameters.n_threads = (int)thread_count;
  parameters.print_progress = false;
  parameters.print_realtime = false;
  parameters.print_timestamps = false;
  parameters.no_timestamps = false;
  parameters.no_context = true;
  parameters.single_segment = false;
  parameters.suppress_blank = true;
  parameters.language = language_utf8;

  if (whisper_full(context->runtime, parameters, samples, (int)sample_count) !=
      0) {
    return VOICE_WHISPER_STATUS_INFERENCE_FAILED;
  }
  const int runtime_segment_count = whisper_full_n_segments(context->runtime);
  if (runtime_segment_count < 0) {
    return VOICE_WHISPER_STATUS_INFERENCE_FAILED;
  }
  output->segment_count = (size_t)runtime_segment_count;
  size_t transcript_length = 0;
  for (int index = 0; index < runtime_segment_count; index += 1) {
    const char *text = whisper_full_get_segment_text(context->runtime, index);
    if (text == NULL) {
      return VOICE_WHISPER_STATUS_INFERENCE_FAILED;
    }
    const size_t length = strlen(text);
    if (SIZE_MAX - transcript_length < length) {
      return VOICE_WHISPER_STATUS_INFERENCE_FAILED;
    }
    transcript_length += length;
  }
  output->transcript_length = transcript_length;
  if (output->transcript_capacity < transcript_length ||
      output->segment_capacity < output->segment_count) {
    return VOICE_WHISPER_STATUS_BUFFER_TOO_SMALL;
  }

  size_t offset = 0;
  for (int index = 0; index < runtime_segment_count; index += 1) {
    const char *text = whisper_full_get_segment_text(context->runtime, index);
    const size_t length = strlen(text);
    if (length > 0) {
      memcpy(output->transcript_utf8 + offset, text, length);
    }
    output->segments[index] = (VoiceWhisperSegmentV1){
        .start_milliseconds =
            whisper_full_get_segment_t0(context->runtime, index) * 10,
        .end_milliseconds =
            whisper_full_get_segment_t1(context->runtime, index) * 10,
        .text_offset = offset,
        .text_length = length,
    };
    offset += length;
  }
  return VOICE_WHISPER_STATUS_OK;
}
