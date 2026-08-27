import AVFAudio
import SwiftUI
import VoiceProbeShared

@main
struct VoiceProbeApp: App {
  @StateObject private var model = VoiceProbeAppModel()

  var body: some Scene {
    WindowGroup {
      VoiceProbeView(model: model)
        .onReceive(
          NotificationCenter.default.publisher(
            for: AVAudioSession.interruptionNotification
          )
        ) { notification in
          model.handleInterruption(notification)
        }
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
    }
  }
}

private struct VoiceProbeView: View {
  @ObservedObject var model: VoiceProbeAppModel

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text("iOS voice feasibility")
            .font(.largeTitle.bold())
          Text(
            "The app owns local microphone capture. The custom keyboard controls an active session and inserts its result."
          )
          .foregroundStyle(.secondary)
        }

        statusCard

        Button {
          if model.isRecording {
            model.stop()
          } else {
            model.start()
          }
        } label: {
          Label(
            model.isRecording ? "Stop local capture" : "Start local capture",
            systemImage: model.isRecording ? "stop.fill" : "mic.fill"
          )
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(
          model.isRecording ? "stop_capture" : "start_capture"
        )

        VStack(alignment: .leading, spacing: 8) {
          Text("Enable the keyboard").font(.headline)
          Text(
            "Settings → General → Keyboard → Keyboards → Add New Keyboard → Voice Keyboard. Full Access is needed only for the same-team local keychain handoff; this probe contains no networking code."
          )
          .foregroundStyle(.secondary)
        }

        if let errorMessage = model.errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .accessibilityIdentifier("capture_error")
        }

        Spacer()
      }
      .padding(24)
      .navigationTitle("Voice Probe")
    }
  }

  private var statusCard: some View {
    HStack(spacing: 12) {
      Image(systemName: statusSymbol)
        .font(.title2)
      VStack(alignment: .leading, spacing: 2) {
        Text(statusTitle).font(.headline)
        Text(statusDetail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    .accessibilityIdentifier("capture_status")
  }

  private var statusSymbol: String {
    switch model.snapshot.phase {
    case .idle: "circle"
    case .recording: "waveform"
    case .transcribing: "ellipsis"
    case .ready: "checkmark.circle.fill"
    case .interrupted: "exclamationmark.triangle"
    case .failed: "xmark.circle"
    }
  }

  private var statusTitle: String {
    model.snapshot.phase.rawValue.capitalized
  }

  private var statusDetail: String {
    switch model.snapshot.phase {
    case .idle: "Ready for local capture."
    case .recording: "Recording locally. Switch to the keyboard and tap its mic to stop."
    case .transcribing: "Finalizing the local K0 handoff."
    case .ready: "Result ready for one-time keyboard insertion."
    case .interrupted: "Capture stopped after an audio interruption. Start again manually."
    case .failed: "Capture stopped with an explicit failure."
    }
  }
}
