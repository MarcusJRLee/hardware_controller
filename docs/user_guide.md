# User guide

## Requirements

- Apple-silicon Mac, macOS 15+, and a VEC Infinity USB-3 (IN-USB-3) pedal.
- Accessibility and Microphone permission; Speech Recognition too on macOS
  15–25. macOS Dictation does not need to be enabled.
- For Local AI Dictation: Apple Intelligence on macOS 26+, or a local
  [Ollama](https://ollama.com) service.

## Install

Build and install the signed app (see the README commands), then open exactly
`/Applications/Hardware Controller.app`. macOS ties permissions to that path
and signature, so install before granting them; the app blocks Actions when run
from a disk image. A personal build is not notarized: if macOS warns, Control-
click the app and choose **Open**.

## First use

1. Plug in the pedal. Status changes from **Controller disconnected** to
   **Ready**, meaning the app exclusively owns the pedal, so its buttons no
   longer act as mouse clicks.
2. Press each pedal; its drawing turns blue and shows **PRESSED**.
3. Follow each amber card to allow Accessibility, Microphone, and (macOS 15–25)
   Speech Recognition. If a card stays after you allow it, relaunch once.
4. Click a text field, hold the center pedal, speak, and release.

The center pedal defaults to Local Dictation in Hold mode; left and right
default to No Action.

## Actions

| Action | What happens |
| --- | --- |
| No Action | Nothing. |
| Local Dictation | Live on-device speech. Fields that support it show words as you speak; others get final text on release. |
| Local AI Dictation | One corrected, formatted result after release, refined by Apple On-Device or local Ollama. |
| Keyboard Shortcut | Sends one recorded chord per press. Needs Accessibility only. |

**Hold** runs while the pedal is down. **Toggle** starts on one press and
finishes on the next. Choose both per pedal under **Controller** or a Profile.

The target app, field, and empty caret are captured when Dictation starts and
rechecked before every change. If focus or the caret moves, insertion stops and
**Copy Text** keeps the result. Password fields are never used. Web fields get
one payload on release; Terminal and Cursor's terminal get sanitized text with
no Return, so a command is never submitted. Where a field cannot show live text,
a click-through HUD near the caret shows it instead.

## Local AI Dictation

Set it up under **General → Local AI Dictation**:

1. Pick **Apple On-Device** or **Ollama**. For Ollama, run `ollama pull
   qwen3.5:4b` (the measured recommendation; 3.4 GB on disk, about 5.7 GB in
   memory) and pick the model.
2. Pick a **Style**: Natural, Casual Message, Formal, Technical, or Verbatim
   (no model; only spoken edits and Dictionary replacements).
3. Pick **Casing**: Style Default, Lowercase Prose, or Strict Lowercase. URLs,
   paths, code, quotes, and Dictionary values keep their spelling.
4. Choose **Refresh Status**, then **Test Selected Provider** (uses a fixed
   phrase; no microphone or field access).
5. Optionally add **Personal dictionary** terms or replacements, nearby-text
   context (off by default), or extra instructions.
6. Assign **Local AI Dictation** to a pedal.

On release the app finalizes speech, applies spoken edits and Dictionary
replacements, asks the model for paragraph or list blocks, validates that
meaning and protected terms survived, then inserts once. Lists are kept in
multiline fields and flattened into one line elsewhere. If the model is
missing, changed, invalid, or takes more than three seconds, the app inserts
the deterministic **Edited** transcript instead and says why.

Spoken commands are exact; near misses stay as text:

| Say | Result |
| --- | --- |
| `scratch that` | Remove the current clause. |
| `delete that sentence` | Remove the current sentence. |
| `new paragraph` | Paragraph break, or the next numbered item inside a list. |
| `start a numbered list` / `start a bullet list` | Begin a list. |
| `bullet` / `next item` | Next item in the active list. |
| `end list` | Finish the list. |
| `literal <command>` | Type the command words instead. |

Ollama is reached only at `http://127.0.0.1:11434`; redirects, proxies, cloud
models, and changed digests are rejected. Apple On-Device never uses Private
Cloud Compute.

## Voice chord and keyboard fallbacks

- **Voice chord** (**General → Voice capture shortcut**): record a chord with at
  least two modifiers. Hold it to dictate with Local AI, or press twice quickly
  to latch and twice again to finish. Works with no pedal. Off by default.
- **Keyboard fallback** (per pedal): choose **Use suggested ⌃⇧⌘D** or record a
  chord. It triggers that pedal's Action while the pedal is unplugged, for the
  active Profile only.

The app reserves only the exact chords you record and never reads other
keystrokes. If another app owns a chord, record a different one.

## Profiles

A Profile is a named set of pedal Bindings, such as Coding and Music. Create,
duplicate, rename, and edit them under **Profiles**; switch from the sidebar or
menu bar. Switching ends active Actions first. Two identical pedals share one
setup because the hardware has no trustworthy serial number.

## History

Local AI sessions keep one local recording plus every text stage (Raw,
Edited, Formatted, Delivered) under the app's Application Support folder.
**History** lets you:

- search every stage, inspect provenance, and play timed audio;
- save a **Correction** (appended, never overwriting). When a correction fixes
  a misheard term, **Add to Dictionary?** offers it; nothing is added until you
  choose **Add**;
- **Retranscribe** retained audio or **Reformat** with another Style;
- **Copy**, or **Insert in 3 Seconds** into a freshly focused field;
- **Export** or **Import** a portable `.voice_history` archive, or import an
  audio file (never inserted automatically);
- **Pin** audio to protect it from cleanup, or **Delete** a session.

Audio cleanup (**General → Voice History storage**) defaults to 90 days, 2 GiB,
or 5,000 recordings, whichever comes first; transcripts always remain.
Interrupted recordings reappear as **Recovered** for 24 hours unless pinned.

## Settings and files

| Setting | Where |
| --- | --- |
| Appearance, microphone, Local AI, Voice chord, storage, Launch at Login | **General** |
| Profiles | `~/Library/Application Support/com.longdevity.hardwarecontroller/profiles.json` |
| Preferences | `preferences.json` in the same folder |
| History | `voice/` in the same folder |

The microphone choice affects only this app. If the saved input disappears, the
system default is used until it returns. To reset, quit and move
`profiles.json` or `preferences.json` to the Trash. Invalid files are kept as a
recovery copy; files from a newer app are left untouched.

## iOS: Voice Input

1. Install with `scripts/install_ios.sh` and open **Voice Input**.
2. Prepare the starter model on the Mac with
   `scripts/prepare_ios_asr_model_package.sh <dir>`, copy the folder into
   Files, then **Local models → Import Model package → Use for speech to text**.
3. Enable the **Voice Input** keyboard (with Full Access for the result
   handoff).

The app records and transcribes; iOS forbids microphone use inside a keyboard.
Start from the keyboard, the app, Control Center, the Lock Screen, the Action
button, or Siri/Shortcuts. The keyboard inserts the result once; if the field
does not confirm it, **Recover…** offers one retry or a local copy that expires
in ten minutes. Everything else falls back to **Voice Input → History**, where
audio cleanup defaults to 90 days, 1 GiB, or 2,000 recordings. The app has no
network access and never downloads models.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Pedal still clicks | Quit every other copy, open only the Applications copy, choose **Retry**. |
| **Controller unavailable** | Another copy or pedal utility owns the device; quit it and choose **Retry**. |
| Pressed, but no dictation | Check the Action is a Dictation Action, permissions are granted, and a normal (non-password) field has focus. |
| A Control–Option chord starts macOS Dictation | That pedal is a Keyboard Shortcut; change it to Local Dictation. |
| Text stopped after switching apps | Intentional; start again or use **Copy Text**. |
| Dictation stopped after changing microphones | The session ends when the input changes; start again. |
| Stuck on **Finalizing** | It fails within five seconds and keeps text in **Copy Text**; relaunch if not. |
| Locale or model unavailable | Let macOS finish installing speech assets; the app never falls back to server recognition. |
| Apple On-Device unavailable | Needs macOS 26, Apple Intelligence on, and its assets installed; otherwise use Ollama. |
| Ollama unavailable | Start Ollama, check `ollama list`, pull the model, then **Refresh Status**. Reselect a changed digest only if you trust it. |
| Inserted the Edited transcript | The card explains the provider, timeout, or validation reason; **Copy Raw** stays available. |

## Privacy

No account, analytics, telemetry, or cloud service. Speech recognition and
models run on-device. Local Dictation keeps audio and text in memory only.
Local AI Dictation and iOS store recordings and transcripts locally in History
until cleanup or deletion. Speech content is never logged. Nearby-text context
reads at most a small window around the caret in a nonsecure multiline field,
and never URLs, terminals, whole documents, screenshots, or the pasteboard.

## Remove

Turn off **Launch at Login**, quit, and move the app to the Trash. Optionally
remove it from Privacy & Security and delete its Application Support folder.
