# Decision 0046: iOS capture lifecycle and recovery

**Status:** Accepted

## Context

The containing app alone can own microphone capture. iOS may interrupt that
ownership for calls, Siri, route changes, media-service loss, background
expiration, or thermal pressure. A stopped recording must remain recoverable
without inventing transcript evidence, automatically resuming sensitive
capture, or allowing one damaged artifact to hide valid History.

| Criterion | Explicit lifecycle policy plus Recovery History | Automatic resume | Delete interrupted audio |
| --- | --- | --- | --- |
| Capture ownership | Exact | Ambiguous after interruption | Ends exactly |
| Privacy-sensitive resume | Never | Implicit | Never |
| Partial-audio recovery | 24 hours | Uncertain | None |
| Damaged-artifact isolation | Preserve and skip | Unspecified | Destructive |
| Background finalization | Bounded OS task | Unbounded assumption | Abandoned |

## Decision

- Keep `AVAudioSession`, `AVAudioRecorder`, Live Activity, background-task, and
  lifecycle-notification APIs behind actor-owned boundaries. The keyboard
  extension receives none of them.
- Require a visible Live Activity for background recording. Entering background
  without that ownership stops capture and preserves its partial audio.
- Stop for interruption begins, actual input-route swaps, media-service loss,
  critical thermal pressure, and background-finalization expiration. Category
  and override notifications continue with an advisory because they do not by
  themselves prove that the physical route changed. Low Power Mode and serious
  thermal pressure also continue with explicit advisories.
- Never resume automatically after an interruption. A later capture requires a
  fresh user or approved system action.
- Record into one lowercase session-UUID `.partial` beneath protected,
  backup-excluded History audio storage. Before releasing capture, commit
  interrupted audio as a schema-revision-2 Recovery session with a typed reason
  when storage remains available.
- Give stopped-recording transcription one bounded iOS background task. Its
  expiration ends that OS task, invalidates the in-flight result, and preserves
  the exact partial as `backgroundExecutionExpired` recovery.
- On first History access after launch, adopt only readable, nonempty, exact
  lowercase session-UUID `.partial` or unreferenced `.caf` artifacts. Preserve
  unknown, noncanonical, unreadable, or empty files untouched so they cannot
  block unrelated History and are never deleted by a broad sweep. If a
  completed session and exact partial share an identifier, remove the partial
  only when its digest matches committed audio; recover differing audio under a
  new identifier.
- Retain Recovery audio as the sole evidence for 24 hours, then store its typed
  expiration while keeping the truthful empty History session. Recovery UI
  offers playback and states that no transcript exists.

## Verification

Pure policy tests cover capture ownership, every route category, low power, and
thermal states. Actor tests cover interruption ordering, visible-activity
backgrounding, bounded-finalization expiration, stale result rejection, and
audio-session/Live Activity release. Real SQLite/filesystem tests cover exact
partial and orphan adoption, schema migration, 24-hour expiry, invalid-artifact
isolation, and unknown-file preservation. Notification mapping is exhaustive
under Swift 6 strict concurrency.

Calls, Siri, lock, real route swaps, system recording indication, background
expiration, and thermal pressure remain signed physical-iPhone evidence. The
paired phone is still blocked only by the unrelated three-app free-profile
limit; no installed app is removed automatically.

## Implications

I7 is implemented in source without changing the keyboard's cold-start or
delivery contract. Recovery can preserve playable audio but cannot promise a
transcript or automatic reuse. Broader startup quarantine, low-disk pressure,
and retranscription controls remain later I10 work.

## Sources

- [Apple handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
- [Apple responding to audio route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)
- [Apple Audio Recording Intent](https://developer.apple.com/documentation/appintents/audiorecordingintent)
- [Apple Low Power Mode](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled)
- [Apple power and thermal notifications](https://developer.apple.com/documentation/xcode/responding-to-power-notifications)
- [Apple background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
