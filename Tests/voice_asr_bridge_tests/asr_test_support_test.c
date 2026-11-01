#include "asr_test_support.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>

static size_t distance(const char *reference, const char *hypothesis) {
  AsrWords left = {0};
  AsrWords right = {0};
  assert(asr_words_from_text(reference, &left) == 0);
  assert(asr_words_from_text(hypothesis, &right) == 0);
  const size_t result = asr_word_edit_distance(&left, &right);
  asr_words_free(&left);
  asr_words_free(&right);
  return result;
}

int main(void) {
  const double latencies[] = {9.0, 1.0, 5.0, 3.0, 7.0};
  assert(asr_percentile(latencies, 5, 0.5) == 5.0);
  assert(asr_percentile(latencies, 5, 0.95) == 9.0);
  assert(asr_percentile(latencies, 5, 0.0) == 1.0);
  assert(asr_percentile(latencies, 0, 0.5) == 0.0);
  assert(asr_percentile(latencies, 5, 1.5) == 0.0);

  AsrWords words = {0};
  assert(asr_words_from_text("  Ask NOT, what's -- yours?! ", &words) == 0);
  assert(words.count == 4);
  assert(strcmp(words.items[0], "ask") == 0);
  assert(strcmp(words.items[2], "what's") == 0);
  asr_words_free(&words);

  assert(distance("ask not what", "Ask not, what.") == 0);
  assert(distance("ask not what", "ask what") == 1);
  assert(distance("ask not", "ask not now") == 1);
  assert(distance("ask not", "task knot") == 2);
  assert(distance("", "") == 0);

  char *buffer = NULL;
  size_t length = 0;
  FILE *stream = open_memstream(&buffer, &length);
  assert(stream != NULL);
  asr_write_json_string(stream, "a\"b\\c\n\x01");
  fclose(stream);
  assert(strcmp(buffer, "\"a\\\"b\\\\c\\n\\u0001\"") == 0);
  free(buffer);
  return 0;
}
