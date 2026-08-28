import ActivityKit
import AppIntents
import SwiftUI
import VoiceInputShared
import WidgetKit

struct VoiceInputControl: ControlWidget {
  static let kind = VoiceInputEnvironment.systemCaptureControlKind

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(
      kind: Self.kind,
      provider: VoiceInputCaptureControlValueProvider()
    ) { isRecording in
      ControlWidgetToggle(
        "Voice Capture",
        isOn: isRecording,
        action: VoiceInputSetCaptureIntent()
      ) { value in
        Label(
          value ? "Recording" : "Ready",
          systemImage: value ? "stop.fill" : "mic.fill"
        )
      }
    }
    .displayName("Voice Capture")
    .description("Start or stop app-owned local voice capture.")
  }
}

private struct VoiceInputCaptureControlValueProvider: ControlValueProvider {
  let previewValue = false

  func currentValue() async throws -> Bool {
    let snapshot = try VoiceInputKeychainStore().readSnapshot()
    return VoiceInputSystemCapturePolicy().isRecording(
      snapshot: snapshot,
      now: .now
    )
  }
}

struct VoiceInputLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: VoiceInputActivityAttributes.self) { context in
      HStack(spacing: 10) {
        Image(systemName: "waveform")
        Text(label(for: context.state.phase))
        Spacer()
        if context.state.phase == .recording {
          Button(intent: VoiceInputStopIntent()) {
            Label("Stop", systemImage: "stop.fill")
          }
          .buttonStyle(.borderedProminent)
        }
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
        DynamicIslandExpandedRegion(.trailing) {
          if context.state.phase == .recording {
            Button(intent: VoiceInputStopIntent()) {
              Image(systemName: "stop.fill")
            }
            .accessibilityLabel("Stop local capture")
          }
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
