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
| Voice session History | Local session document containing separate Raw, Edited, Formatted, and Delivered text plus at most one audio artifact. |
| Audio artifact recorder | Bounded nonblocking tee from immutable capture buffers to an atomically finalized local CAF. |
| Voice session store | Actor-owned system SQLite connection that serializes local session metadata transactions. |
| Voice trigger | Input adapter that maps physical, exact-chord, or in-app intent into the shared Voice-session contract. |
| Voice chord | Optional machine-wide exact shortcut dedicated to Voice capture and independent of Binding keyboard fallbacks. |
| Latched capture | Voice capture kept active after a valid double press until the next valid double press. |
| Refinement provider | Typed local text-to-text boundary implemented by Apple Foundation Models or fixed-loopback Ollama. |
| Target lease | Captured editable element, process, caret/selection, and delivery capability revalidated before mutation. |
| Nearby context | Optional bounded text around the caret from an approved nonsecure multiline target, held only for one Local AI session. |
| Personal dictionary | Machine-wide recognition vocabulary plus deterministic spoken-form replacements. |
| Prompt revision | Source-controlled invariant refinement policy and typed provider payload version evaluated against the fixed corpus. |
| Release evidence | Version-specific record tying source, verification, signing metadata, and artifact hashes to one explicitly accepted artifact. |
