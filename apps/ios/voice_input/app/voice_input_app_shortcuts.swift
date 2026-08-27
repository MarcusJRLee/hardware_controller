import AppIntents

struct VoiceInputAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: VoiceInputStartIntent(),
      phrases: [
        "Start \(.applicationName)",
        "Start local capture with \(.applicationName)",
      ],
      shortTitle: "Start Voice Capture",
      systemImageName: "mic.fill"
    )
    AppShortcut(
      intent: VoiceInputStopIntent(),
      phrases: [
        "Stop \(.applicationName)",
        "Finish capture with \(.applicationName)",
      ],
      shortTitle: "Stop Voice Capture",
      systemImageName: "stop.fill"
    )
  }
}
