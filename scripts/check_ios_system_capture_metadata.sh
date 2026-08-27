#!/bin/zsh

set -euo pipefail

app_bundle="${1:?Pass the built VoiceInput.app path.}"
app_metadata="$app_bundle/Metadata.appintents/extract.actionsdata"
widget_metadata="$app_bundle/PlugIns/VoiceInputWidgets.appex/Metadata.appintents/extract.actionsdata"

command -v jq >/dev/null || {
  print -u2 "jq is required for the iOS system-capture metadata check."
  exit 1
}

for metadata in "$app_metadata" "$widget_metadata"; do
  [[ -f "$metadata" ]] || {
    print -u2 "Missing generated App Intents metadata: $metadata"
    exit 1
  }
  for action in \
    VoiceInputStartIntent \
    VoiceInputStopIntent \
    VoiceInputSetCaptureIntent; do
    jq -e --arg action "$action" '.actions[$action] != null' "$metadata" \
      >/dev/null || {
      print -u2 "$metadata does not expose $action."
      exit 1
    }
  done
done

jq -e '
  .actions.VoiceInputStartIntent.openAppWhenRun == true
  and .actions.VoiceInputStopIntent.openAppWhenRun == false
  and .actions.VoiceInputSetCaptureIntent.openAppWhenRun == true
  and (.actions.VoiceInputStartIntent.systemProtocols | index("com.apple.link.systemProtocol.AudioRecording") != null)
  and (.actions.VoiceInputStopIntent.systemProtocols | index("com.apple.link.systemProtocol.AudioRecording") != null)
  and (.actions.VoiceInputSetCaptureIntent.systemProtocols | index("com.apple.link.systemProtocol.SetValue") != null)
  and ([.autoShortcuts[].actionIdentifier] | sort == ["VoiceInputStartIntent", "VoiceInputStopIntent"])
' "$app_metadata" >/dev/null || {
  print -u2 "The containing app has incomplete system-capture metadata."
  exit 1
}

jq -e '
  (.actions.VoiceInputStartIntent.systemProtocols | index("com.apple.link.systemProtocol.AudioRecording") != null)
  and (.actions.VoiceInputStopIntent.systemProtocols | index("com.apple.link.systemProtocol.AudioRecording") != null)
  and (.actions.VoiceInputStopIntent.systemProtocols | index("com.apple.link.systemProtocol.SessionStarting") != null)
  and (.actions.VoiceInputSetCaptureIntent.systemProtocols | index("com.apple.link.systemProtocol.AudioRecording") != null)
  and (.actions.VoiceInputSetCaptureIntent.systemProtocols | index("com.apple.link.systemProtocol.SetValue") != null)
' "$widget_metadata" >/dev/null || {
  print -u2 "The Widget extension has incomplete system-capture metadata."
  exit 1
}

print "iOS system-capture metadata: PASS"
