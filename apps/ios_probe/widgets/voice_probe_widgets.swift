import ActivityKit
import AppIntents
import SwiftUI
import VoiceProbeShared
import WidgetKit

struct VoiceProbeStartIntent: AudioRecordingIntent {
  static let title: LocalizedStringResource = "Start local voice capture"
  static let description = IntentDescription(
    "Opens Voice Probe and starts an app-owned local recording."
  )
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    let store = VoiceProbeKeychainStore()
    try store.writeCommand(.start(sessionID: UUID(), issuedAt: .now))
    return .result()
  }
}

struct VoiceProbeControl: ControlWidget {
  static let kind = "com.longdevity.hardwarecontroller.voiceprobe.start"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      ControlWidgetButton(action: VoiceProbeStartIntent()) {
        Label("Voice Capture", systemImage: "mic.fill")
      }
    }
    .displayName("Voice Capture")
    .description("Start an app-owned local voice capture.")
  }
}

struct VoiceProbeLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: VoiceProbeActivityAttributes.self) { context in
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

  private func label(for phase: VoiceProbeSnapshot.Phase) -> String {
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
struct VoiceProbeWidgetsBundle: WidgetBundle {
  var body: some Widget {
    VoiceProbeLiveActivity()
    VoiceProbeControl()
  }
}
