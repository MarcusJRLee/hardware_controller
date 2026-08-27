# Context

Canonical product language lives in
[`docs/product_brief.md`](docs/product_brief.md#canonical-language). These names
identify deep implementation modules without changing that language.

| Term | Meaning |
| --- | --- |
| Application runtime | Process-owned actor that serializes lifecycle, Profile transactions, permission-derived availability, hot-key replacement, speech warm-up, and immutable presentation snapshots. |
| Speech input | Configuration-leased microphone capture plus an on-device Apple recognition session. It copies callback-owned samples before crossing isolation. |
| Dictation coordinator | Process-wide serial owner that cancels one Dictation workflow before beginning the other. |
| Local Dictation controller | Existing live-composition workflow. It owns recognition, adaptive target delivery, finalization, and recovery without model refinement. |
| Local AI Dictation controller | Final-only workflow that composes recognition, starts model preparation during speech, validates refinement, delivers refined or Raw fallback once, and finalizes one Voice session. |
| Voice session History | Searchable local archive whose session owns at most one audio artifact and an append-only graph of immutable Raw, Edited, Formatted, Delivered, and corrected results. |
| Audio artifact recorder | Bounded nonblocking tee from immutable capture buffers to an atomically finalized local CAF. |
| Voice session store | Actor-owned system SQLite connection that serializes local session metadata transactions. |
| Voice History service | Actor that retranscribes retained audio, reformats reusable text, retries delivery, and appends each outcome as a linked immutable result. |
| Voice audio importer | Actor that bounds a user-selected recording, runs local ASR/formatting, streams one app-owned CAF, and commits typed imported-audio History without mutating the source. |
| Voice History archive | Bounded portable directory containing one V1 manifest, one checksum contract, and optional CAF; it preserves immutable evidence without representing a mutable store. |
| Voice archive importer | Actor that privately snapshots, verifies, and transactionally restores one Voice History archive without delivery. |
| Reusable result | Newest nonempty result selected deterministically from one session for copy, correction, retranscription, reformatting, export, or explicit re-delivery. |
| Voice trigger | Input adapter that maps physical, exact-chord, or in-app intent into the shared Voice-session contract. |
| Voice chord | Optional machine-wide exact shortcut dedicated to Voice capture and independent of Binding keyboard fallbacks. |
| Latched capture | Voice capture kept active after a valid double press until the next valid double press. |
| Refinement provider | Typed local text-to-text boundary implemented by Apple Foundation Models or fixed-loopback Ollama. |
| Portable Voice core | Dependency-free Rust domain policy shared through versioned CUJ fixtures; it contains no platform lifecycle or UI behavior. |
| Portable archive verifier | Safe Rust boundary that verifies the exact Voice History inventory, limits, identities, and digests before a platform decodes and restores typed evidence. |
| Voice FFI | Versioned synchronous C ABI over portable Voice crates; callers own every buffer and no pointer survives a call. |
| Target lease | Captured editable element, process, caret/selection, and delivery capability revalidated before mutation. |
| Nearby context | Optional bounded text around the caret from an approved nonsecure multiline target, held only for one Local AI session. |
| Personal dictionary | Machine-wide recognition vocabulary plus deterministic spoken-form replacements. |
| Prompt revision | Source-controlled invariant refinement policy and typed provider payload version evaluated against the fixed corpus. |
| Release evidence | Version-specific record tying source, verification, signing metadata, and artifact hashes to one explicitly accepted artifact. |
