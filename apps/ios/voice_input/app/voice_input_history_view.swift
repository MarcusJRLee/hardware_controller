import HardwareControllerCore
import SwiftUI
import VoiceInputShared

struct VoiceInputHistoryView: View {
  @ObservedObject var model: VoiceInputHistoryModel
  @ObservedObject var audioPlayer: VoiceInputHistoryAudioPlayerModel

  var body: some View {
    NavigationStack {
      List {
        if let errorMessage = model.errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .accessibilityIdentifier("history_error")
        }
        ForEach(model.sessions) { session in
          NavigationLink {
            VoiceInputHistoryDetailView(
              session: session,
              audioPlayer: audioPlayer,
              setPinned: { isPinned in
                Task { await model.setPinned(sessionID: session.id, isPinned: isPinned) }
              }
            )
          } label: {
            VoiceInputHistoryRow(session: session)
          }
        }
      }
      .listStyle(.plain)
      .overlay {
        if model.sessions.isEmpty, model.errorMessage == nil, !model.isLoading {
          ContentUnavailableView(
            model.query.isEmpty ? "No dictations yet" : "No matches",
            systemImage: "waveform",
            description: Text(
              model.query.isEmpty
                ? "Finished dictations and recovered audio appear here."
                : "Try different words."
            )
          )
          .accessibilityIdentifier("history_empty")
        }
      }
      .navigationTitle("History")
      .searchable(text: $model.query, prompt: "Search transcripts")
      .onSubmit(of: .search) { Task { await model.search() } }
      .onChange(of: model.query) { _, query in
        if query.isEmpty { Task { await model.refresh() } }
      }
      .refreshable { await model.refresh() }
      .accessibilityIdentifier("voice_history")
    }
  }
}

private struct VoiceInputHistoryRow: View {
  let session: VoiceInputHistorySession

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(session.isRecovery ? "Recovered recording" : session.formattedText)
        .lineLimit(3)
        .foregroundStyle(session.isRecovery ? .secondary : .primary)
      HStack(spacing: 6) {
        Text(session.endedAt, format: .relative(presentation: .named))
        if !session.isRecovery {
          Text("·")
          Text(session.style.kind.displayName)
        }
        if session.isPinned {
          Image(systemName: "pin.fill").accessibilityLabel("Pinned")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("history_row")
  }
}

private struct VoiceInputHistoryDetailView: View {
  let session: VoiceInputHistorySession
  @ObservedObject var audioPlayer: VoiceInputHistoryAudioPlayerModel
  let setPinned: (Bool) -> Void
  @State private var copyMessage: String?
  private let localClipboard = VoiceInputSystemLocalClipboard()

  var body: some View {
    List {
      Section {
        if session.isRecovery {
          VStack(alignment: .leading, spacing: 6) {
            Text(session.recoveryDescription ?? "Recovered recording")
            Text(
              session.isPinned
                ? "Pinned recovery audio stays until you unpin it."
                : "Play it before its 24-hour recovery window ends."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
          }
        } else {
          Text(session.formattedText)
            .textSelection(.enabled)
            .accessibilityIdentifier("history_text")
        }
      }

      if !session.isRecovery {
        Section {
          Button {
            copy()
          } label: {
            Label(copyMessage ?? "Copy text", systemImage: "doc.on.doc")
          }
          .accessibilityIdentifier("history_copy")
          ShareLink(item: session.formattedText) {
            Label("Share", systemImage: "square.and.arrow.up")
          }
          .accessibilityIdentifier("history_share")
        }
      }

      Section {
        if session.audioArtifact != nil {
          Button {
            audioPlayer.toggle(session)
          } label: {
            Label(
              isPlaying ? "Stop playback" : "Play recording",
              systemImage: isPlaying ? "stop.fill" : "play.fill"
            )
          }
          Button {
            setPinned(!session.isPinned)
          } label: {
            Label(
              session.isPinned ? "Unpin audio" : "Keep audio",
              systemImage: session.isPinned ? "pin.slash" : "pin"
            )
          }
          .accessibilityIdentifier("history_pin")
        } else {
          Text(session.audioExpiredReason?.displayDescription ?? "Audio unavailable")
            .foregroundStyle(.secondary)
        }
        if let errorMessage = audioPlayer.errorMessage {
          Text(errorMessage).foregroundStyle(.red)
        }
      } header: {
        Text("Audio")
      }

      if !session.isRecovery {
        Section {
          DisclosureGroup("Raw transcript") {
            Text(session.rawText)
              .font(.subheadline)
              .textSelection(.enabled)
          }
        } footer: {
          Text(
            "\(session.style.kind.displayName) · \(session.modelPackageID) \(session.modelVersion)")
        }
      }
    }
    .navigationTitle(Text(session.endedAt, format: .dateTime.month().day().hour().minute()))
    .navigationBarTitleDisplayMode(.inline)
    .onDisappear { audioPlayer.stop() }
  }

  private var isPlaying: Bool {
    audioPlayer.playingSessionID == session.id
  }

  private func copy() {
    do {
      try localClipboard.copy(session.formattedText)
      copyMessage = "Copied for 10 minutes"
    } catch {
      copyMessage = "Too large to copy safely"
    }
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

extension VoiceHistoryAudioExpirationReason {
  fileprivate var displayDescription: String {
    switch self {
    case .ageLimit:
      "Audio expired at its age limit; transcript kept."
    case .artifactLimit:
      "Audio expired at the recording-count limit; transcript kept."
    case .byteLimit:
      "Audio expired at the total-size limit; transcript kept."
    case .lowDisk:
      "Audio expired to protect free space; transcript kept."
    case .recoveryLimit:
      "Recovered audio expired after 24 hours."
    }
  }
}
