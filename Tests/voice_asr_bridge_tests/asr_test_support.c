#include "asr_test_support.h"

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint16_t little_u16(const uint8_t *bytes) {
  return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t little_u32(const uint8_t *bytes) {
  return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
         ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

int asr_read_wave(const char *path, float **samples, size_t *sample_count) {
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

static int compare_doubles(const void *left, const void *right) {
  const double a = *(const double *)left;
  const double b = *(const double *)right;
  return (a > b) - (a < b);
}

double asr_percentile(const double *values, size_t count, double percentile) {
  if (values == NULL || count == 0 || percentile < 0.0 || percentile > 1.0) {
    return 0.0;
  }
  double *sorted = malloc(count * sizeof(*sorted));
  if (sorted == NULL) {
    return 0.0;
  }
  memcpy(sorted, values, count * sizeof(*sorted));
  qsort(sorted, count, sizeof(*sorted), compare_doubles);
  /* Nearest rank: the smallest value with at least p of samples at or below. */
  size_t rank = (size_t)(percentile * (double)count + 0.999999999);
  rank = rank == 0 ? 1 : rank;
  const double value = sorted[(rank > count ? count : rank) - 1];
  free(sorted);
  return value;
}

void asr_words_free(AsrWords *words) {
  if (words == NULL) {
    return;
  }
  for (size_t index = 0; index < words->count; index += 1) {
    free(words->items[index]);
  }
  free(words->items);
  *words = (AsrWords){0};
}

/*
 * Lowercases ASCII and splits on anything other than letters, digits, and
 * apostrophes, so punctuation and casing never count as recognition errors.
 * Non-ASCII bytes are kept as word characters.
 */
int asr_words_from_text(const char *text, AsrWords *output) {
  *output = (AsrWords){0};
  if (text == NULL) {
    return 1;
  }
  size_t capacity = 0;
  const char *cursor = text;
  while (*cursor != '\0') {
    while (*cursor != '\0' &&
           !(isalnum((unsigned char)*cursor) || *cursor == '\'' ||
             (unsigned char)*cursor >= 0x80)) {
      cursor += 1;
    }
    const char *start = cursor;
    while (*cursor != '\0' &&
           (isalnum((unsigned char)*cursor) || *cursor == '\'' ||
            (unsigned char)*cursor >= 0x80)) {
      cursor += 1;
    }
    const size_t length = (size_t)(cursor - start);
    if (length == 0) {
      continue;
    }
    if (output->count == capacity) {
      capacity = capacity == 0 ? 32 : capacity * 2;
      char **grown = realloc(output->items, capacity * sizeof(*grown));
      if (grown == NULL) {
        asr_words_free(output);
        return 1;
      }
      output->items = grown;
    }
    char *word = malloc(length + 1);
    if (word == NULL) {
      asr_words_free(output);
      return 1;
    }
    for (size_t index = 0; index < length; index += 1) {
      word[index] = (char)tolower((unsigned char)start[index]);
    }
    word[length] = '\0';
    output->items[output->count] = word;
    output->count += 1;
  }
  return 0;
}

size_t asr_word_edit_distance(const AsrWords *reference,
                              const AsrWords *hypothesis) {
  size_t *previous = calloc(hypothesis->count + 1, sizeof(*previous));
  size_t *current = calloc(hypothesis->count + 1, sizeof(*current));
  if (previous == NULL || current == NULL) {
    free(previous);
    free(current);
    return SIZE_MAX;
  }
  for (size_t column = 0; column <= hypothesis->count; column += 1) {
    previous[column] = column;
  }
  for (size_t row = 1; row <= reference->count; row += 1) {
    current[0] = row;
    for (size_t column = 1; column <= hypothesis->count; column += 1) {
      const size_t substitution =
          previous[column - 1] + (strcmp(reference->items[row - 1],
                                         hypothesis->items[column - 1]) != 0);
      const size_t deletion = previous[column] + 1;
      const size_t insertion = current[column - 1] + 1;
      size_t best = substitution < deletion ? substitution : deletion;
      best = insertion < best ? insertion : best;
      current[column] = best;
    }
    size_t *swap = previous;
    previous = current;
    current = swap;
  }
  const size_t distance = previous[hypothesis->count];
  free(previous);
  free(current);
  return distance;
}

void asr_write_json_string(FILE *stream, const char *text) {
  fputc('"', stream);
  for (const unsigned char *cursor = (const unsigned char *)text;
       *cursor != '\0'; cursor += 1) {
    switch (*cursor) {
    case '"':
      fputs("\\\"", stream);
      break;
    case '\\':
      fputs("\\\\", stream);
      break;
    case '\n':
      fputs("\\n", stream);
      break;
    case '\r':
      fputs("\\r", stream);
      break;
    case '\t':
      fputs("\\t", stream);
      break;
    default:
      if (*cursor < 0x20) {
        fprintf(stream, "\\u%04x", *cursor);
      } else {
        fputc(*cursor, stream);
      }
    }
  }
  fputc('"', stream);
}
