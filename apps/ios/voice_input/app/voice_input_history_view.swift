import HardwareControllerVoiceCore
import SwiftUI

struct VoiceInputHistoryView: View {
  @ObservedObject var model: VoiceInputHistoryModel
  @ObservedObject var audioPlayer: VoiceInputHistoryAudioPlayerModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("History")
        .font(.title2.bold())
        .accessibilityIdentifier("voice_history")
      Text("Completed recordings and every transcript stage stay on this iPhone.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      TextField("Search transcripts", text: $model.query)
        .textFieldStyle(.roundedBorder)
        .submitLabel(.search)
        .onSubmit { Task { await model.search() } }
        .accessibilityIdentifier("history_search")

      if model.isLoading {
        ProgressView("Loading local History")
      } else if model.sessions.isEmpty, model.errorMessage == nil {
        ContentUnavailableView(
          "No completed recordings",
          systemImage: "waveform",
          description: Text("Finished captures will appear here.")
        )
        .accessibilityIdentifier("history_empty")
      }

      if let errorMessage = model.errorMessage ?? audioPlayer.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .accessibilityIdentifier("history_error")
      }

      ForEach(model.sessions) { session in
        VoiceInputHistorySessionView(
          session: session,
          isPlaying: audioPlayer.playingSessionID == session.id,
          togglePlayback: { audioPlayer.toggle(session) }
        )
      }
    }
  }
}

private struct VoiceInputHistorySessionView: View {
  let session: VoiceInputHistorySession
  let isPlaying: Bool
  let togglePlayback: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(session.endedAt, style: .date).font(.headline)
        Text(session.endedAt, style: .time)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        Text(session.style.kind.displayName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(session.formattedText)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack {
        Button(action: togglePlayback) {
          Label(
            isPlaying ? "Stop recording" : "Play recording",
            systemImage: isPlaying ? "stop.fill" : "play.fill"
          )
        }
        .disabled(session.audioArtifact == nil)

        if session.audioArtifact == nil {
          Text("Audio expired; transcript retained")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      DisclosureGroup("Raw transcript") {
        Text(session.rawText)
          .font(.subheadline)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Text("\(session.modelPackageID) · \(session.modelVersion)")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

extension VoiceStyleKind {
  fileprivate var displayName: String {
    switch self {
    case .natural: "Natural"
    case .casualMessage: "Casual"
    case .formal: "Formal"
    case .technical: "Technical"
    case .verbatim: "Verbatim"
    }
  }
}
