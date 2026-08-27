# 0036: Imported Voice audio

- **Status:** Accepted
- **Date:** 2026-08-27
- **Implements:**
  [`0029_local_voice_platform_expansion.md`](0029_local_voice_platform_expansion.md)

## Context

Voice History must accept a recording the user already owns, run the same local
ASR and formatting boundaries used for History reuse, and never modify or
depend on the external file after import. Compressed input can expand
substantially when decoded, so bounding only source bytes or duration is
insufficient.

Apple documents that `AVAudioFile` reads supported file formats sequentially as
PCM buffers through its processing format. Security-scoped URLs require a
balanced access interval. These documented boundaries support a streaming,
app-owned import without loading an entire recording into memory:

- [AVAudioFile](https://developer.apple.com/documentation/avfaudio/avaudiofile)
- [Security-scoped URL access](https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource%28%29)

## Decision matrix

| Criterion | Keep an external reference | Copy source bytes | Stream to canonical CAF |
| --- | ---: | ---: | ---: |
| Original may move or disappear | 1 | 5 | 5 |
| One playback/retranscription format | 1 | 2 | 5 |
| Bounded working memory | 5 | 5 | 5 |
| Bound compressed and decoded size | 1 | 2 | 5 |
| Crash-safe ownership and cleanup | 1 | 4 | 5 |
| **Total** | **9** | **18** | **25** |

Stream supported input into one app-owned CAF and retain no external reference.

## Contract

- History exposes one native **Import Audio Recording** action. The open panel
  accepts system-declared audio types and balances security-scoped access for
  the complete operation.
- Validate three independently configurable limits before model work: source
  bytes, decoded retained bytes, and duration. macOS defaults are 2 GiB, 2 GiB,
  and 12 hours. Normal History retention still applies after finalization.
- Read and write sequential 4,096-frame PCM buffers. Sync a session-scoped
  partial CAF, atomically rename it, then commit SQLite. Any failed commit
  removes the owned CAF. The selected source is never changed or deleted.
- Run Apple on-device ASR and the selected local Style. Successful formatting
  stores Raw, Edited, and structured Formatted evidence. Formatting failure
  stores the Raw transcript as the deterministic Formatted fallback. ASR
  failure stores audio with empty text for explicit History retranscription.
- Imported sessions have typed `importedAudio` input provenance and an
  `audioImport` Raw-result origin. Existing rows and older JSON decode as
  `microphoneCapture`.
- Import never inserts text automatically. Delivery is `notAttempted`; copy,
  correction, reformat, export, and explicit re-delivery remain History actions.
- Cancellation before persistence creates neither a row nor an owned artifact.
- Export manifest revision 4 carries input provenance.

## Consequences

The external filename and path are not retained. Imported audio consumes the
same age, byte, count, pin, and low-disk budget as captured audio. The current
adapter supports every audio format `AVAudioFile` can decode on the running
system; unsupported, empty, oversized, or corrupt files fail without History
mutation.

Portable ASR remains a later measured adapter. It can consume the owned CAF
without changing import provenance, storage, UI, or fallback behavior.

## Evidence

- `Tests/HardwareControllerMacTests/voice_audio_import_service_test.swift`
- `Tests/HardwareControllerMacTests/voice_audio_artifact_importer_test.swift`
- `Tests/HardwareControllerAppTests/voice_history_model_test.swift`
- `Tests/HardwareControllerCoreTests/voice_session_test.swift`
- `Tests/HardwareControllerMacTests/sqlite_voice_session_store_test.swift`
- `Tests/HardwareControllerMacTests/voice_history_exporter_test.swift`
