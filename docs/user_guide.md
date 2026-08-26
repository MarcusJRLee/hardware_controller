# Hardware Controller user guide

## Requirements

- Apple-silicon Mac running macOS 15 or later.
- VEC Infinity USB-3 / IN-USB-3 three-pedal USB foot control.
- Accessibility and Microphone permission for either Dictation Action.
- Speech Recognition permission on macOS 15 through 25.
- For Local AI Dictation: Apple On-Device on macOS 26, or a separately
  installed local Ollama service and model.

Hardware Controller does not need macOS Dictation to be enabled and does not
use its keyboard shortcut.

## Install or update

1. Quit every running Hardware Controller copy.
2. Follow the signed personal-build commands in
   [`README.md`](../README.md#build-and-verify). Verify the signature against
   the private `HC_EXPECTED_TEAM_ID`, then replace the Applications copy only
   when that install is explicitly approved.
3. Open exactly `/Applications/Hardware Controller.app`.

Move the app before granting permissions. macOS ties privacy grants to the
installed path and code signature. The app blocks actions and Launch at Login
when it is opened from a mounted disk image.

This personal build is Apple Development signed but is not notarized for
public distribution. If macOS displays a warning, Control-click the installed
app, choose **Open**, and confirm **Open**.

The application identifier changed to `com.longdevity.hardwarecontroller`.
Profiles and preferences use its matching Application Support directory. macOS
may request Accessibility, Microphone, Speech Recognition, or Launch at Login
authorization again for a newly signed identity.

Opening the app manually presents or raises Controller. The left sidebar opens
expanded with Controller, Profiles, and General and can be collapsed with the
native toolbar control. Hardware Controller appears in the Dock while running.
The pedal-shaped menu-bar item switches Profiles, opens each destination,
controls Launch at Login, and quits the app.

Updating the app preserves local Profiles. Schema-1 and schema-2 Bindings move
into an Infinity 3 Device setup. A version 1 Dictation action is migrated to
Local Dictation and its obsolete shortcut is removed. A generic
Keyboard Shortcut remains a keyboard shortcut because the app cannot safely
guess its purpose. Schema-1 application preferences migrate with System
Default selected for Local Dictation. Existing Bindings remain unchanged when
the Local AI Action and preferences are added.

## Connect the pedal

1. Plug in the Infinity 3. Use a direct Mac or powered-hub connection for the
   first test.
2. Confirm the status changes from **Controller disconnected** to **Ready**.
3. Press left, center, and right. The matching rendered pedal must compress,
   turn blue, and display **PRESSED**.
4. Confirm no press produces a primary, secondary, or middle mouse click.

Ready means Hardware Controller exclusively owns only the narrowly matched VEC
device, preventing macOS from also interpreting its buttons as pointer clicks.

## Allow the required permissions

Follow each amber card in the app:

1. **Allow focused-app control** opens
   **Privacy & Security → Accessibility**. Enable Hardware Controller. This
   lets it identify the selected editable field, replace only the live text
   inserted by the current session, and send configured keyboard shortcuts.
   It reads field text only when optional Local AI nearby context is enabled,
   then only from a bounded nonsecure multiline target. It never reads the
   global keyboard event stream. An optional keyboard fallback receives only
   its explicitly registered chord.
2. **Allow microphone access** requests Microphone access. Audio is captured
   only while Local Dictation is active, kept in memory, and never saved.
3. On macOS 15–25, **Allow speech recognition** requests Speech Recognition
   access. The legacy backend refuses to start unless on-device recognition is
   supported. macOS 26+ uses Apple's newer local SpeechAnalyzer assets and
   does not require this separate permission.

The cards should disappear within one second after authorization. If one
remains, quit and reopen the installed app once.

## Configure Local Dictation

Each pedal has its own Action:

- **No Action** produces no output.
- **Local Dictation** owns microphone capture, on-device recognition, and text
  insertion. It supports Hold and Toggle.
- **Local AI Dictation** reuses local capture and recognition, then inserts one
  validated corrected and formatted result. It supports Hold and Toggle.
- **Keyboard Shortcut** sends one complete configured chord per press.

For the center pedal:

1. Choose **Local Dictation**, not Keyboard Shortcut.
2. Choose **Hold** for press-to-talk or **Toggle** for press-on/press-off.
3. Complete the permission cards.
4. Scroll to **Dictation test** and click its field.
5. Hold the center pedal while speaking, then release it.

If your existing center action shows `⌃⌥P`, `⌃⌥M`, or another
Control–Option chord, it is still a generic Keyboard Shortcut. The app
deliberately shows a warning. Change its Action picker to **Local Dictation**;
do not configure a matching shortcut in macOS Keyboard settings.

## Use Local Dictation

### Hold

1. Put the insertion point in an editable field.
2. Press and hold the assigned control.
3. Confirm the pedal displays **PRESSED**.
4. Speak. Compatible fields show recognized words immediately. Final-only
   editors and terminals show a temporary transcript HUD once words exist.
5. Release the pedal. The transcript is committed and the HUD disappears.

### Toggle

1. Select an editable field.
2. Press once to start.
3. Speak.
4. Press again to finalize and insert text.

Hardware Controller chooses delivery from the focused editor's Accessibility
capabilities:

- If the editor exposes a stable, editable selection range, provisional words
  appear in the field while you speak. Recognition corrections replace only
  the provisional suffix inserted by this session; committed words are never
  selected again.
- If the editor cannot prove safe range ownership, the temporary HUD shows the
  live transcript and the field receives final text when you release the
  pedal.
- Editable web content buffers the transcript and receives one foreground
  Unicode payload when you release the pedal. Detection uses standard
  Accessibility ancestry, not browser or website identity.
- Native Terminal and Cursor's integrated terminal buffer the transcript until
  release, then type one sanitized final payload at the unchanged caret.
  Hardware Controller never sends Return, so it cannot submit the command.

The target application, element, and empty insertion range are captured at
begin and rechecked before every mutation. Password fields and existing text
selections are never used for live composition. If focus or the caret moves,
automatic insertion stops, recognized final text stays visible, and
**Copy Text** provides explicit recovery without automatically changing the
clipboard.

Starting a new session clears the previous presentation transcript. Local
Dictation audio and text remain memory-only. On the M1 development branch,
Local AI Dictation stores one local CAF and its final text stages under the
app's Application Support directory; History UI and automatic retention are
not implemented yet. Speech content is never logged.

## Configure Local AI Dictation

Open **General → Local AI Dictation** before assigning the Action:

1. Choose **Apple On-Device** or **Ollama**.
2. For Ollama, start the local service and install the recommended model:

   ```bash
   ollama pull qwen3.5:4b
   ```

3. Choose an installed model and **5 minutes** or **Until app quits** retention.
   On model change or quit, the app unloads a model it started. It leaves a
   model that was already running for another local Ollama client untouched.
4. Choose **Refresh Status**, then **Test Selected Provider**. The test uses a
   fixed sanitized phrase without microphone or focused-field access.
5. Optionally expand **Personal dictionary**. Type a recognition term into its
   outlined field and choose **Add**, or fill both outlined replacement fields
   before choosing **Add**. You can also enable nearby-text context or provide
   formatting instructions.
6. Assign **Local AI Dictation** to a Control under Controller or Profiles.

Apple On-Device requires macOS 26, Apple Intelligence enabled, a supported
locale, and installed model assets. It never enables Private Cloud Compute.
Ollama is contacted only at `http://127.0.0.1:11434`; the app verifies the
installed model digest and will not silently accept changed weights. The
recommended Qwen 3.5 4B model uses about 3.39 GB on disk and measured 5.74 GB
resident on the reference Mac.

Recognition vocabulary helps Apple's speech backend identify names and
technical terms. Exact replacements run deterministically after recognition
and before the model. Additional instructions can express style preferences,
but cannot override accuracy, privacy, or prompt-safety rules.

Nearby text is off by default. When enabled, the app reads at most a bounded
window around the caret from an approved multiline, nonsecure Accessibility
target for the current session. Single-line fields, browsers' compatibility
routes, terminals, secure fields, URLs, whole documents, screenshots, and the
pasteboard never provide context.

## Use Local AI Dictation

Hold and Toggle controls work exactly as they do for Local Dictation. During
speech, recognized words appear only in the temporary HUD. After release, the
app:

1. finalizes on-device Apple speech recognition;
2. applies exact dictionary replacements;
3. corrects and formats text through the selected local provider;
4. validates meaning, protected terms, target capability, and output shape;
5. inserts one result into the unchanged target.

Formatting is automatic. Clear lists or steps become bullets or numbered lists
only in safe multiline targets; single-line and compatibility targets always
receive one plain line. There is no Clean/Structured setting.

Model warm-up begins while you speak. If warm-up plus generation does not
finish within three seconds after the final raw transcript, or the provider is
missing, changed, overloaded, or returns invalid text, the app inserts the raw
transcript once when the original target is still safe. Controller explains
the fallback. **Copy Raw** and **Copy Refined** remain separate recovery actions
when their respective text exists. Cancellation, focus change, or caret change
discards late model output.

## Configure keyboard shortcuts

Choose **Keyboard Shortcut**, then **Record**, and press the desired chord.
The shortcut runs once per pedal press. Press Escape while recording to cancel
without changing it.

Keyboard shortcuts are independent of Local Dictation. They still require
Accessibility but not Microphone or Speech Recognition access.

## Use Voice capture without a Device

The optional Voice chord is machine-wide and independent of Profiles,
Controls, and Binding keyboard fallbacks. It runs the current Local AI
Dictation pipeline, including its microphone, Apple on-device recognition,
selected local refinement provider, safe target delivery, and local M1 session
storage.

1. Open **General → Voice capture shortcut**.
2. Choose **Record** and press an exact chord with at least two modifier keys.
3. Focus a nonsecure editable field.
4. Hold the chord, speak, then release it to finish; or press it twice quickly
   to keep listening and twice again to finish.
5. Use **Clear shortcut** to stop reserving the chord.

Capture begins on the first key-down; it does not wait to distinguish a hold
from a double press. Repeated key-down events and unmatched releases do nothing.
Changing the chord, sleeping, or quitting cancels active capture. If macOS or
another app owns the exact chord, General keeps the setting visible and asks
you to record a different one. The Voice chord is off by default and works
without a connected Device.

## Use a keyboard fallback without the pedal

Every configured Control can have one optional shortcut that triggers the
Control's existing Action and Hold/Toggle behavior.

1. Open **Controller** or the selected Profile's Device setup.
2. Choose an Action other than **No Action**.
3. Under **Keyboard fallback**, choose **Use suggested ⌃⇧⌘D** or record an
   exact alternative.
4. Use **Clear** to stop reserving that chord.

The fallback is active only for the active Profile and works while the pedal is
disconnected. It is not enabled automatically for new or migrated Profiles.
For Hold behavior, press and hold the chord; release it to end. If the pedal and
shortcut overlap, the Action ends only after both release. For Toggle, each
distinct pedal or keyboard press changes state.

Hardware Controller reserves only the exact configured chord; it does not read
other global keystrokes. If macOS or another app already owns the chord, the
Control editor asks you to record another. A Profile cannot use the same
fallback twice or use a fallback that matches one of its output Keyboard
Shortcut Actions. Every fallback requires at least two modifier keys.

Changes save immediately at:

`~/Library/Application Support/com.longdevity.hardwarecontroller/profiles.json`

## Create and switch Profiles

Profiles are named work modes. Use Coding for development shortcuts and Music
for transport or recording shortcuts without reconfiguring the same Device.

1. Open **Profiles** in the sidebar.
2. Create a Profile, or duplicate the selected Profile to preserve its complete
   Device setup.
3. Rename it and add the connected Device setup if needed.
4. Configure each Control independently.
5. Choose **Make Active**, the sidebar Active Profile picker, or the menu-bar
   Profile picker.

Switching ends active Actions before the selected Profile becomes active. A
Control held during the switch must be released and pressed again. Profiles
can be edited while inactive without changing current Device behavior.

Two identical Infinity 3 units share one model-level setup because the Driver
does not expose a trustworthy per-unit identifier. The app never assigns
durable per-unit behavior from an ephemeral connection order.

## Choose the Local Dictation microphone

Open **General → Dictation microphone** and choose **System Default** or one listed
input Device. The choice affects Hardware Controller only; it does not change
the macOS default input. Changing it ends active Dictation and prepares the new
route. If the saved Device is disconnected, the app temporarily uses the
current system default and resumes the saved Device after reconnect.

## Understand the live state

- No cursor or pointer badge is shown for idle, ready, not-ready, completed, or
  failed state. Open Controller or the menu-bar item for status and recovery.
- A temporary blue **Listening** HUD appears only when the active target cannot
  show provisional text inline. Its second line is the current live transcript.
- A live-capable field shows words directly and never needs the HUD.
- Blue and **PRESSED**: the physical Control is down.
- Mint outline/glow: a stateful configured Action is active.
- Amber and **PRESSED · BLOCKED**: hardware input arrived, but a required
  permission or installation condition blocks that Action.
- **Preparing / Listening / Finalizing**: authoritative app-owned
  transcription phases.
- **Refining / Validating / Delivering**: Local AI is preparing one final
  result; automatic insertion has not occurred until Delivering.
- **Transcription needs attention**: the status card explains the failure and
  offers **Copy Text** when final text is recoverable.
- **Local AI Dictation complete**: refined text or a labeled raw fallback was
  inserted once. Raw and refined recovery remain distinct.

A transcription failure appears once in its dedicated card. It does not add a
second generic Action failure card or move the Controller layout.

Physical pressed state remains visible even when an Action is blocked.

## Launch at login

Enable **Launch at Login** in General or the menu-bar menu. Login-item launches
start quietly; manually opening the app shows or raises Controller.

Choose System, Light, or Dark in **General → Appearance**. System follows the
Mac. Appearance, microphone selection, Local AI settings, and collapsed
sidebar state persist separately from Profiles at `preferences.json` in the
same Application Support directory. Speech content and target context do not.

## Troubleshooting

### The pedal still clicks or right-clicks

- Confirm only the current Applications copy is running.
- Confirm the app displays **Ready**.
- Quit every old, disk-image, or repository copy and open only the Applications
  copy.
- Choose **Retry** if another process previously owned the pedal.

### Pressed state appears, but no transcription starts

- Confirm the Action is **Local Dictation** or **Local AI Dictation**, not
  Keyboard Shortcut or No Action.
- Complete the Accessibility and Microphone cards; on macOS 15–25 also
  complete Speech Recognition.
- Click a normal editable field before pressing the pedal.
- Do not test in a password field.
- Check the transcription status card for locale, model, audio, focus, or
  insertion recovery guidance.

### The selected microphone is missing

- Open **General → Local Dictation** to confirm the saved selection.
- Reconnect that input Device; the picker marks a saved missing Device as
  unavailable.
- Until it returns, both Dictation Actions use the current system default.
- Choose another Device to replace the saved selection.

### A Control–Option shortcut still starts macOS Dictation

That pedal is configured as **Keyboard Shortcut**, so macOS owns the chord.
Change the Action to **Local Dictation**, which does not use a macOS Dictation
shortcut.

### Text stopped after I changed apps or fields

This is intentional focus safety. Return to the original field and start a new
session, or use **Copy Text** if the failed session retained final text.

### Dictation stopped after I changed microphones

The app ends the current session if the input Device, sample rate, or channel
layout changes. Start Dictation again after macOS finishes switching. Capture
rebuilds against the current input instead of reusing the old configuration.

### I see a temporary HUD in web content, a terminal, or an editor

The target cannot safely show revisable provisional text inline. Keep speaking:
the HUD remains live and disappears after final text is delivered.

Editable web content receives final text through the foreground input path.
The app never submits the field.

Native Terminal and Cursor's integrated terminal receive buffered final text
as guarded Unicode keyboard input at the unchanged caret. The adapter strips
Return, Tab, escape, and other command-submitting controls; it never executes
the command. If no final text appears, confirm the same field and caret stayed
focused and check Controller for an insertion error.

### The app stays on Finalizing

The app turns an unresponsive finalizer or unexpected recognition termination
into an explicit failure within five seconds and keeps committed text available
through **Copy Text**. If recovery does not appear, quit and reopen the app.

### The app says the locale or model is unavailable

- Confirm the Mac language/locale is supported by Apple's speech frameworks.
- On macOS 26+, allow macOS to finish installing its local speech asset and
  retry.
- On macOS 15–25, the app will not fall back to server recognition when the
  locale lacks on-device support.

### Apple On-Device Local AI is unavailable

- Confirm the Mac runs macOS 26 or later and supports Apple Intelligence.
- Enable Apple Intelligence and allow its model assets to finish installing.
- Confirm the current locale is supported, then choose **Refresh Status**.
- Select Ollama if Apple On-Device is not available on this Mac.

### Ollama is unavailable or the model is missing

- Start Ollama and confirm `ollama list` shows the selected local model.
- Install the recommendation with `ollama pull qwen3.5:4b`.
- Return to **General → Local AI Dictation**, refresh status, and select the
  installed model.
- If the digest changed, reselect the model only after deciding to trust the
  new local weights. The app never accepts drift silently.

### Local AI inserted the raw transcript

Controller states the provider, timeout, overload, or validation reason. The
raw fallback is intentional and is delivered only once. Check provider status,
try a shorter utterance, or disable nearby context if a custom model copied
unrelated target text. **Copy Raw** remains available for the current recovery
state.

### The app says Controller unavailable

Another Hardware Controller copy or pedal utility owns the device. Quit every
copy, open only `/Applications/Hardware Controller.app`, and choose **Retry**.

### Reset Profiles and preferences

Quit Hardware Controller, move `profiles.json` from the Application Support
path above to the Trash, and reopen the app. Move `preferences.json` as well to
reset appearance, sidebar visibility, microphone selection, and Local AI
settings. Invalid JSON
detected by the app is preserved as a recovery copy before safe defaults load.
A valid file from a newer app is left untouched and requires that newer app.

## Remove

1. Turn off **Launch at Login** and quit Hardware Controller.
2. Move the app from Applications to the Trash.
3. Optionally remove Hardware Controller from Accessibility, Microphone, and
   Speech Recognition in System Settings.
4. Optionally delete its Application Support folder to remove Profiles and
   application preferences.

## Privacy boundary

Hardware Controller has no account, analytics, telemetry, cloud service, or
remote model provider. Microphone audio, transcripts, nearby context, prompts,
and generated text exist only in memory for the current session and are not
logged. On macOS 26+, Apple speech and Foundation Models use installed local
assets. On macOS 15–25, speech requests set
`requiresOnDeviceRecognition = true` and fail closed when local recognition is
unavailable. Ollama requests use only fixed numeric loopback; redirects, proxy
routing, cloud tags, and remote endpoints are rejected.
