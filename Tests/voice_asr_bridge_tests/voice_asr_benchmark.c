/*
 * Measures one ASR model on a fixed corpus through the production bridge.
 *
 * Usage: voice_asr_benchmark MODEL SPEECH_MODEL|- MANIFEST.tsv PASSES
 *        DETECT_SPEECH USE_GPU
 *
 * Each manifest line is `id<TAB>relative/audio.wav<TAB>human reference`.
 * One full-corpus warm-up pass is excluded from statistics. Output is JSONL:
 * one model line, one line per clip from the first measured pass, and one
 * summary with latency percentiles, median real-time factor, and word errors.
 */
#include "asr_test_support.h"
#include "voice_asr_bridge.h"

#include <errno.h>
#include <libgen.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct Clip {
  char *identifier;
  char *reference;
  float *samples;
  size_t sample_count;
} Clip;

typedef struct Corpus {
  Clip *clips;
  size_t count;
} Corpus;

static double now_seconds(void) {
  struct timespec time = {0};
  clock_gettime(CLOCK_MONOTONIC, &time);
  return (double)time.tv_sec + (double)time.tv_nsec / 1000000000.0;
}

static void free_corpus(Corpus *corpus) {
  for (size_t index = 0; index < corpus->count; index += 1) {
    free(corpus->clips[index].identifier);
    free(corpus->clips[index].reference);
    free(corpus->clips[index].samples);
  }
  free(corpus->clips);
}

static int load_corpus(const char *manifest_path, Corpus *corpus) {
  *corpus = (Corpus){0};
  FILE *manifest = fopen(manifest_path, "r");
  if (manifest == NULL) {
    return 1;
  }
  char *directory_copy = strdup(manifest_path);
  if (directory_copy == NULL) {
    fclose(manifest);
    return 1;
  }
  const char *directory = dirname(directory_copy);
  char *line = NULL;
  size_t line_capacity = 0;
  int status = 0;
  while (status == 0 && getline(&line, &line_capacity, manifest) > 0) {
    line[strcspn(line, "\r\n")] = '\0';
    if (line[0] == '\0' || line[0] == '#') {
      continue;
    }
    char *audio = strchr(line, '\t');
    char *reference = audio == NULL ? NULL : strchr(audio + 1, '\t');
    if (audio == NULL || reference == NULL) {
      status = 1;
      break;
    }
    *audio++ = '\0';
    *reference++ = '\0';
    char path[4096];
    if (snprintf(path, sizeof(path), "%s/%s", directory, audio) >=
        (int)sizeof(path)) {
      status = 1;
      break;
    }
    Clip *grown = realloc(corpus->clips, (corpus->count + 1) * sizeof(*grown));
    if (grown == NULL) {
      status = 1;
      break;
    }
    corpus->clips = grown;
    Clip *clip = &corpus->clips[corpus->count];
    *clip = (Clip){.identifier = strdup(line), .reference = strdup(reference)};
    corpus->count += 1;
    if (clip->identifier == NULL || clip->reference == NULL ||
        asr_read_wave(path, &clip->samples, &clip->sample_count) != 0) {
      fprintf(stderr, "Unreadable corpus clip: %s\n", path);
      status = 1;
    }
  }
  free(line);
  free(directory_copy);
  fclose(manifest);
  if (status == 0 && corpus->count == 0) {
    status = 1;
  }
  if (status != 0) {
    free_corpus(corpus);
    *corpus = (Corpus){0};
  }
  return status;
}

/* Returns the transcript as a new null-terminated string, or NULL. */
static char *transcribe(VoiceASRContext *context, const Clip *clip,
                        uint8_t detect_speech, uint32_t *status) {
  static uint8_t transcript[1048576];
  static VoiceASRSegmentV1 segments[4096];
  VoiceASRRequestV1 request = {.language_utf8 = "auto",
                               .detect_speech = detect_speech};
  VoiceASRResultV1 result = {
      .transcript_utf8 = transcript,
      .transcript_capacity = sizeof(transcript) - 1,
      .segments = segments,
      .segment_capacity = sizeof(segments) / sizeof(segments[0]),
  };
  *status = voice_asr_transcribe_v1(context, clip->samples, clip->sample_count,
                                    &request, &result);
  if (*status == VOICE_ASR_STATUS_NO_SPEECH) {
    return strdup("");
  }
  if (*status != VOICE_ASR_STATUS_OK) {
    return NULL;
  }
  transcript[result.transcript_length] = '\0';
  return strdup((const char *)transcript);
}

static int parse_flag(const char *text, unsigned long maximum,
                      unsigned long *value) {
  char *end = NULL;
  errno = 0;
  *value = strtoul(text, &end, 10);
  return errno != 0 || end == text || *end != '\0' || *value > maximum;
}

int main(int argument_count, char **arguments) {
  unsigned long passes = 0;
  unsigned long detect_speech = 0;
  unsigned long use_gpu = 0;
  if (argument_count != 7 || parse_flag(arguments[4], 100, &passes) ||
      passes == 0 || parse_flag(arguments[5], 1, &detect_speech) ||
      parse_flag(arguments[6], 1, &use_gpu)) {
    fprintf(stderr, "usage: voice_asr_benchmark MODEL SPEECH_MODEL|- "
                    "MANIFEST.tsv PASSES DETECT_SPEECH USE_GPU\n");
    return 2;
  }
  Corpus corpus = {0};
  if (load_corpus(arguments[3], &corpus) != 0) {
    fprintf(stderr, "The manifest is missing, empty, or malformed.\n");
    return 3;
  }
  voice_asr_runtime_configure_v1(0);
  const char *speech_model =
      strcmp(arguments[2], "-") == 0 ? NULL : arguments[2];
  VoiceASRContext *context = NULL;
  const double load_start = now_seconds();
  if (voice_asr_context_create_v1(arguments[1], speech_model, (uint8_t)use_gpu,
                                  8, &context) != VOICE_ASR_STATUS_OK) {
    free_corpus(&corpus);
    return 4;
  }
  const double load_seconds = now_seconds() - load_start;
  printf("{\"type\":\"model\",\"model\":");
  asr_write_json_string(stdout, basename(arguments[1]));
  printf(",\"load_ms\":%.3f,\"detect_speech\":%lu,\"use_gpu\":%lu}\n",
         load_seconds * 1000.0, detect_speech, use_gpu);

  const size_t sample_total = corpus.count * passes;
  double *latencies = calloc(sample_total, sizeof(*latencies));
  double *real_time_factors = calloc(sample_total, sizeof(*real_time_factors));
  int exit_status = latencies == NULL || real_time_factors == NULL ? 5 : 0;
  size_t reference_words = 0;
  size_t word_edits = 0;
  for (unsigned long pass = 0; pass <= passes && exit_status == 0; pass += 1) {
    for (size_t index = 0; index < corpus.count && exit_status == 0;
         index += 1) {
      const Clip *clip = &corpus.clips[index];
      uint32_t status = 0;
      const double start = now_seconds();
      char *text = transcribe(context, clip, (uint8_t)detect_speech, &status);
      const double elapsed = now_seconds() - start;
      if (text == NULL) {
        fprintf(stderr, "Clip %s failed with bridge status %u.\n",
                clip->identifier, status);
        exit_status = 6;
        break;
      }
      if (pass > 0) {
        const size_t sample = (pass - 1) * corpus.count + index;
        latencies[sample] = elapsed * 1000.0;
        real_time_factors[sample] =
            elapsed / ((double)clip->sample_count / 16000.0);
      }
      if (pass == 1) {
        AsrWords reference = {0};
        AsrWords hypothesis = {0};
        if (asr_words_from_text(clip->reference, &reference) != 0 ||
            asr_words_from_text(text, &hypothesis) != 0) {
          exit_status = 5;
        } else {
          const size_t edits = asr_word_edit_distance(&reference, &hypothesis);
          reference_words += reference.count;
          word_edits += edits;
          printf("{\"type\":\"clip\",\"id\":");
          asr_write_json_string(stdout, clip->identifier);
          printf(",\"audio_ms\":%.0f,\"latency_ms\":%.3f,\"word_edits\":%zu,"
                 "\"reference_words\":%zu,\"transcript\":",
                 (double)clip->sample_count / 16.0, elapsed * 1000.0, edits,
                 reference.count);
          asr_write_json_string(stdout, text);
          printf("}\n");
        }
        asr_words_free(&reference);
        asr_words_free(&hypothesis);
      }
      free(text);
    }
  }
  if (exit_status == 0) {
    printf("{\"type\":\"summary\",\"samples\":%zu,\"p50_ms\":%.3f,"
           "\"p95_ms\":%.3f,\"p99_ms\":%.3f,\"max_ms\":%.3f,"
           "\"median_rtf\":%.5f,\"wer\":%.4f}\n",
           sample_total, asr_percentile(latencies, sample_total, 0.50),
           asr_percentile(latencies, sample_total, 0.95),
           asr_percentile(latencies, sample_total, 0.99),
           asr_percentile(latencies, sample_total, 1.0),
           asr_percentile(real_time_factors, sample_total, 0.50),
           reference_words == 0 ? 0.0
                                : (double)word_edits / (double)reference_words);
  }
  free(latencies);
  free(real_time_factors);
  voice_asr_context_destroy_v1(context);
  free_corpus(&corpus);
  return exit_status;
}
