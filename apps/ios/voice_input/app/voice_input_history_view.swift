import HardwareControllerVoiceCore
import SwiftUI
import VoiceInputShared

struct VoiceInputHistoryView: View {
  @ObservedObject var model: VoiceInputHistoryModel
  @ObservedObject var audioPlayer: VoiceInputHistoryAudioPlayerModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("History")
        .font(.title2.bold())
        .accessibilityIdentifier("voice_history")
      Text("Recordings, recovery audio, and every transcript stage stay on this iPhone.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      VoiceInputHistoryStorageView(model: model)

      TextField("Search transcripts", text: $model.query)
        .textFieldStyle(.roundedBorder)
        .submitLabel(.search)
        .onSubmit { Task { await model.search() } }
        .accessibilityIdentifier("history_search")

      if model.isLoading {
        ProgressView("Loading local History")
      } else if model.sessions.isEmpty, model.errorMessage == nil {
        ContentUnavailableView(
          "No recordings",
          systemImage: "waveform",
          description: Text("Finished captures and recovered audio will appear here.")
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
          togglePlayback: { audioPlayer.toggle(session) },
          setPinned: { isPinned in
            Task {
              await model.setPinned(
                sessionID: session.id,
                isPinned: isPinned
              )
            }
          }
        )
      }
    }
  }
}

private struct VoiceInputHistoryStorageView: View {
  @ObservedObject var model: VoiceInputHistoryModel

  var body: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Audio age", selection: ageBinding) {
          Text("Don't retain").tag(Int?.some(0))
          Text("30 days").tag(Int?.some(30))
          Text("90 days").tag(Int?.some(90))
          Text("1 year").tag(Int?.some(365))
          Text("Unlimited").tag(Int?.none)
        }
        .accessibilityIdentifier("history_retention_age")

        Picker("Audio size", selection: byteBinding) {
          Text("Don't retain").tag(Int64?.some(0))
          Text("512 MiB").tag(Int64?.some(512 * 1_024 * 1_024))
          Text("1 GiB").tag(Int64?.some(1_024 * 1_024 * 1_024))
          Text("2 GiB").tag(Int64?.some(2 * 1_024 * 1_024 * 1_024))
          Text("Unlimited").tag(Int64?.none)
        }
        .accessibilityIdentifier("history_retention_size")

        Picker("Recordings", selection: countBinding) {
          Text("Don't retain").tag(Int?.some(0))
          Text("500").tag(Int?.some(500))
          Text("2,000").tag(Int?.some(2_000))
          Text("5,000").tag(Int?.some(5_000))
          Text("Unlimited").tag(Int?.none)
        }
        .accessibilityIdentifier("history_retention_count")

        Text(
          "The first limit reached—or less than 1 GiB of free space—expires the oldest unpinned audio. Transcripts remain searchable."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if model.isUpdatingRetention {
          ProgressView("Updating local storage")
        }

        if let maintenanceMessage = model.maintenanceMessage {
          Label(maintenanceMessage, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("history_storage_status")
        }
      }
      .pickerStyle(.menu)
      .disabled(!model.canUpdateRetention || model.isUpdatingRetention)
      .padding(.top, 8)
    } label: {
      Text("History storage")
        .accessibilityIdentifier("history_storage")
    }
  }

  private var ageBinding: Binding<Int?> {
    Binding(
      get: { model.retentionSettings.maximumAgeDays },
      set: { maximumAgeDays in
        update(
          VoiceHistoryRetentionSettings(
            maximumAgeDays: maximumAgeDays,
            maximumAudioBytes: model.retentionSettings.maximumAudioBytes,
            maximumArtifactCount: model.retentionSettings.maximumArtifactCount
          )
        )
      }
    )
  }

  private var byteBinding: Binding<Int64?> {
    Binding(
      get: { model.retentionSettings.maximumAudioBytes },
      set: { maximumAudioBytes in
        update(
          VoiceHistoryRetentionSettings(
            maximumAgeDays: model.retentionSettings.maximumAgeDays,
            maximumAudioBytes: maximumAudioBytes,
            maximumArtifactCount: model.retentionSettings.maximumArtifactCount
          )
        )
      }
    )
  }

  private var countBinding: Binding<Int?> {
    Binding(
      get: { model.retentionSettings.maximumArtifactCount },
      set: { maximumArtifactCount in
        update(
          VoiceHistoryRetentionSettings(
            maximumAgeDays: model.retentionSettings.maximumAgeDays,
            maximumAudioBytes: model.retentionSettings.maximumAudioBytes,
            maximumArtifactCount: maximumArtifactCount
          )
        )
      }
    )
  }

  private func update(_ settings: VoiceHistoryRetentionSettings) {
    Task { await model.updateRetentionSettings(settings) }
  }
}

private struct VoiceInputHistorySessionView: View {
  let session: VoiceInputHistorySession
  let isPlaying: Bool
  let togglePlayback: () -> Void
  let setPinned: (Bool) -> Void
  private let localClipboard = VoiceInputSystemLocalClipboard()
  @State private var copyMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(session.endedAt, style: .date).font(.headline)
        Text(session.endedAt, style: .time)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        if session.isRecovery {
          Text("Recovered audio")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text(session.style.kind.displayName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if session.isPinned {
          Label("Pinned", systemImage: "pin.fill")
            .font(.caption)
        }
      }

      if session.isRecovery {
        Label("Recovered recording", systemImage: "waveform.badge.exclamationmark")
          .font(.headline)
        if let recoveryDescription = session.recoveryDescription {
          Text(recoveryDescription)
            .foregroundStyle(.secondary)
        }
        Text("No transcript was created for this recovery.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        if session.audioArtifact != nil {
          Text(
            session.isPinned
              ? "Pinned recovery audio remains until you unpin it."
              : "Play this recording before its 24-hour recovery window ends."
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
      } else {
        Text(session.formattedText)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Button(action: togglePlayback) {
          Label(
            isPlaying ? "Stop recording" : "Play recording",
            systemImage: isPlaying ? "stop.fill" : "play.fill"
          )
        }
        .disabled(session.audioArtifact == nil)

        if session.audioArtifact != nil {
          Button {
            setPinned(!session.isPinned)
          } label: {
            Label(
              session.isPinned ? "Unpin audio" : "Pin audio",
              systemImage: session.isPinned ? "pin.slash" : "pin"
            )
          }
          .accessibilityIdentifier("history_pin")
        }

        if !session.isRecovery {
          Button {
            copyTranscript()
          } label: {
            Label("Copy text", systemImage: "doc.on.doc")
          }
          .accessibilityIdentifier("history_copy")
        }

        if session.audioArtifact == nil {
          Text(session.audioExpiredReason?.displayDescription ?? "Audio unavailable")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let copyMessage {
        Text(copyMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("history_copy_status")
      }

      if !session.isRecovery {
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
    }
    .padding(16)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func copyTranscript() {
    do {
      try localClipboard.copy(session.formattedText)
      copyMessage = "Copied on this device for 10 minutes."
    } catch {
      copyMessage = "This transcript is too large to copy safely."
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
      "Audio expired at its age limit; transcript retained"
    case .artifactLimit:
      "Audio expired at the recording-count limit; transcript retained"
    case .byteLimit:
      "Audio expired at the total-size limit; transcript retained"
    case .lowDisk:
      "Audio expired to protect free space; transcript retained"
    case .recoveryLimit:
      "Recovered audio expired after 24 hours"
    }
  }
}
