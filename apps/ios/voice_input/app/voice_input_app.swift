import AVFAudio
import SwiftUI
import UIKit
import VoiceInputShared

@main
struct VoiceInputApp: App {
  @StateObject private var model = VoiceInputAppModel()

  var body: some Scene {
    WindowGroup {
      VoiceInputView(model: model)
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

private struct VoiceInputView: View {
  @ObservedObject var model: VoiceInputAppModel
  @Environment(\.openURL) private var openURL

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Voice anywhere. Private by default.")
              .font(.largeTitle.bold())
            Text(
              "Capture long thoughts without sending audio, transcripts, or context off this iPhone."
            )
            .foregroundStyle(.secondary)
          }

          VoiceInputOnboardingView(
            step: model.onboardingStep,
            microphoneAuthorization: model.microphoneAuthorization,
            keyboardHandoffObserved: model.keyboardHandoffObserved,
            errorMessage: model.onboardingErrorMessage,
            requestMicrophone: model.requestMicrophone,
            openSettings: openSettings
          )

          captureSection

          if let errorMessage = model.errorMessage ?? model.snapshotErrorMessage {
            Text(errorMessage)
              .foregroundStyle(.red)
              .accessibilityIdentifier("capture_error")
          }
        }
        .padding(24)
      }
      .navigationTitle("Voice Input")
    }
  }

  private var captureSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Capture").font(.title2.bold())
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
      .disabled(!model.canCapture)
      .accessibilityIdentifier(
        model.isRecording ? "stop_capture" : "start_capture"
      )
    }
  }

  private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      return
    }
    openURL(url)
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
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Capture status")
    .accessibilityValue(statusTitle)
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
    case .transcribing: "Finalizing locally."
    case .ready: "Result ready for one-time keyboard insertion."
    case .interrupted: "Capture stopped after an audio interruption. Start again manually."
    case .failed: "Capture stopped with an explicit failure."
    }
  }
}
