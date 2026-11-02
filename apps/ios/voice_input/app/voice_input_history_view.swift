import HardwareControllerCore
import SwiftUI
import VoiceInputShared

struct VoiceInputHistoryView: View {
  @ObservedObject var model: VoiceInputHistoryModel
  @ObservedObject var audioPlayer: VoiceInputHistoryAudioPlayerModel
  @State private var isConfirmingClearAll = false

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
              },
              delete: { await delete(session) }
            )
          } label: {
            VoiceInputHistoryRow(session: session)
          }
          .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
              Task { await delete(session) }
            }
            .accessibilityIdentifier("history_delete_row")
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
      .toolbar {
        if !model.sessions.isEmpty {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button("Clear All History…", systemImage: "trash", role: .destructive) {
                isConfirmingClearAll = true
              }
              .accessibilityIdentifier("history_clear_all")
            } label: {
              Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("history_menu")
          }
        }
      }
      .confirmationDialog(
        "Delete every dictation and its audio?",
        isPresented: $isConfirmingClearAll,
        titleVisibility: .visible
      ) {
        Button("Clear All History", role: .destructive) {
          Task {
            audioPlayer.stop()
            await model.deleteAll()
          }
        }
        .accessibilityIdentifier("history_confirm_clear_all")
      } message: {
        Text("This can't be undone.")
      }
    }
  }

  private func delete(_ session: VoiceInputHistorySession) async {
    if audioPlayer.playingSessionID == session.id {
      audioPlayer.stop()
    }
    await model.delete(sessionID: session.id)
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
  let delete: () async -> Void
  @State private var copyMessage: String?
  @State private var isConfirmingDelete = false
  @Environment(\.dismiss) private var dismiss
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

      Section {
        Button("Delete Dictation", role: .destructive) {
          isConfirmingDelete = true
        }
        .accessibilityIdentifier("history_delete")
      }
    }
    .navigationTitle(Text(session.endedAt, format: .dateTime.month().day().hour().minute()))
    .navigationBarTitleDisplayMode(.inline)
    .onDisappear { audioPlayer.stop() }
    .confirmationDialog(
      "Delete this dictation and its audio?",
      isPresented: $isConfirmingDelete,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        Task {
          await delete()
          dismiss()
        }
      }
      .accessibilityIdentifier("history_confirm_delete")
    }
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
