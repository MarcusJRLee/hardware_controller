# Decision 0058: Dictionary suggestions from corrections

**Status:** Accepted

## Context

Recognition vocabulary and exact replacements fix names the recognizer
misses, but users add entries only when they think to open Local AI settings.
Hex's vocabulary research found that local dictation products converged on a
short curated list, suggestions learned from explicit edits, and confirmation
before saving. Real-word mishearings such as "capuchin" for "Cappuccino" must
not become blind replacements, because the misheard word is legitimate
elsewhere.

| Criterion | Confirmed suggestions after a correction | Automatic learning | Manual entry only |
| --- | --- | --- | --- |
| User control | Explicit Add per entry | None | Full |
| Risk of corrupting ordinary words | Low; plain words are skipped | High | None |
| Discoverability | At the moment of the fix | Invisible | Low |
| Decision | Selected | Rejected | Previous behavior |

## Decision

- After **Save Correction**, diff the source and corrected text by words with a
  longest common subsequence. Treat more than three edited spans, or more than
  40 percent of the source words, as a rewrite and suggest nothing.
- Suggest only substitutions of one to four words whose replacement looks like
  a name or term: it contains an uppercase letter, a digit, or a symbol. Skip
  insertions, deletions, case-only and punctuation-only edits, and single-word
  inflections.
- Offer the corrected term as recognition vocabulary. Offer a literal
  replacement only when two or more spoken words became the term, such as
  "open code" to "OpenCode". Show at most three suggestions and skip entries
  already in the Dictionary, ignoring case.
- Persist an accepted suggestion through the existing validated Local AI
  settings write. A rejected write leaves the suggestion visible with an error.

## Consequences

- Vocabulary reaches Apple speech through the existing contextual-strings path
  and transcribe.cpp models that declare the vocabulary feature.
- Suggestions are never stored; dismissing them or changing the selection
  discards them.
