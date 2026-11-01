# Decision 0056: iOS live pause-cut decoding

**Status:** Accepted; physical-device evidence open

## Context

iOS transcribed only after Stop, so the wait after release grew with recording
length. Hex streams Parakeet while the user speaks so release waits only for the
remaining audio. Handy cuts long recordings at pauses and decodes each chunk once
its cut is certain. The iOS capture service records with `AVAudioRecorder`,
whose file is the durable History and recovery evidence that
[0046](0046_ios_capture_lifecycle_and_recovery.md) depends on.

| Criterion | Live tap beside the recorder | Replace the recorder with an engine tap | Decode after Stop only |
| --- | --- | --- | --- |
| Wait after release | Last chunk only | Last chunk only | Whole recording |
| Durable audio path | Unchanged | Rewritten, with new interruption and route behavior | Unchanged |
| Failure effect | Falls back to the file | Can lose audio | None |
| Decision | Selected | Rejected for now | Previous behavior |

## Decision

- While recording, an `AVAudioEngine` input tap converts audio to 16 kHz mono
  and feeds `voice_asr_live_*` in order through one actor-owned stream. The tap
  never writes History or recovery files.
- The bridge cuts live audio at a pause of about 600 ms once a chunk holds at
  least 10 seconds, or at the longest pause before 28 seconds. Shorter chunks
  measurably changed words and casing at the cut, so ordinary dictation still
  decodes once at Stop. Decoded audio is released, so memory holds one chunk.
- Stop drains every tapped sample before finishing. The live transcript is used
  only when it succeeded for the selected model and its samples cover the
  recorded file within 0.5 seconds. Any tap failure, feed failure, coverage gap,
  model change, no-speech result, or interruption falls back to transcribing the
  recorded file.
- Live decoding requires the package's speech-detection payload. Packages
  without one keep after-Stop decoding.

## Verification

`scripts/check_voice_asr_bridge.sh` feeds a 37-second, three-utterance clip in
100 ms pieces. Every utterance must decode during feed, the transcript must
equal the batch content with exact word boundaries, and finish must decode only
the tail. A retained result must survive one `BUFFER_TOO_SMALL` retry, silence
must report no speech, and a batch call must end any live decode. Swift tests
cover tap draining, interruption cancellation, tap start failure, the coverage
fallback, and the 16 kHz conversion.

## Consequences

- Concurrent `AVAudioRecorder` and `AVAudioEngine` input on a physical iPhone,
  plus thermal and energy cost, remain open evidence. Until it is measured, the
  live path stays an optimization the file path can always replace.
