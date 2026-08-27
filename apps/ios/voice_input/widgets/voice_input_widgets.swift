import ActivityKit
import AppIntents
import SwiftUI
import VoiceInputShared
import WidgetKit

struct VoiceInputStartIntent: AudioRecordingIntent {
  static let title: LocalizedStringResource = "Start local voice capture"
  static let description = IntentDescription(
    "Opens Voice Input and starts an app-owned local recording."
  )
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    let store = VoiceInputKeychainStore()
    try store.writeCommand(.start(sessionID: UUID(), issuedAt: .now))
    return .result()
  }
}

struct VoiceInputControl: ControlWidget {
  static let kind = "com.longdevity.hardwarecontroller.voiceinput.start"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      ControlWidgetButton(action: VoiceInputStartIntent()) {
        Label("Voice Capture", systemImage: "mic.fill")
      }
    }
    .displayName("Voice Capture")
    .description("Start an app-owned local voice capture.")
  }
}

struct VoiceInputLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: VoiceInputActivityAttributes.self) { context in
      HStack(spacing: 10) {
        Image(systemName: "waveform")
        Text(label(for: context.state.phase))
      }
      .padding()
      .activityBackgroundTint(.black)
      .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "mic.fill")
        }
        DynamicIslandExpandedRegion(.center) {
          Text(label(for: context.state.phase))
        }
      } compactLeading: {
        Image(systemName: "mic.fill")
      } compactTrailing: {
        Text("REC")
      } minimal: {
        Image(systemName: "waveform")
      }
    }
  }

  private func label(for phase: VoiceInputSnapshot.Phase) -> String {
    switch phase {
    case .recording: "Recording locally"
    case .transcribing: "Finalizing locally"
    case .ready: "Result ready"
    case .interrupted: "Recording interrupted"
    case .idle: "Ready"
    case .failed: "Capture failed"
    }
  }
}

@main
struct VoiceInputWidgetsBundle: WidgetBundle {
  var body: some Widget {
    VoiceInputLiveActivity()
    VoiceInputControl()
  }
}
