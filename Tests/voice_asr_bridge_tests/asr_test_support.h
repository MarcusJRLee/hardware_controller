#ifndef ASR_TEST_SUPPORT_H
#define ASR_TEST_SUPPORT_H

#include <stddef.h>
#include <stdio.h>

/* Reads a 16 kHz mono 16-bit PCM WAV file into normalized float samples. */
int asr_read_wave(const char *path, float **samples, size_t *sample_count);

/* Nearest-rank percentile in [0, 1]; returns 0 for empty input. */
double asr_percentile(const double *values, size_t count, double percentile);

typedef struct AsrWords {
  char **items;
  size_t count;
} AsrWords;

int asr_words_from_text(const char *text, AsrWords *output);
void asr_words_free(AsrWords *words);

/* Word-level Levenshtein distance; SIZE_MAX when allocation fails. */
size_t asr_word_edit_distance(const AsrWords *reference,
                              const AsrWords *hypothesis);

void asr_write_json_string(FILE *stream, const char *text);

#endif
