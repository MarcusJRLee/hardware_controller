import AppKit
import HardwareControllerCore
import HardwareControllerMac
import SwiftUI
import UniformTypeIdentifiers

/// Presents searchable immutable Voice sessions as a quiet local tape archive.
struct VoiceHistoryView: View {
  @Bindable var model: VoiceHistoryModel
  @State private var showsDeleteConfirmation = false

  var body: some View {
    HStack(spacing: 0) {
      archiveList
      Divider()
      detail
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .task(id: model.searchQuery) {
      try? await Task.sleep(for: .milliseconds(160))
      guard !Task.isCancelled else {
        return
      }
      await model.load(query: model.searchQuery)
    }
    .alert(
      "Delete this Voice session?",
      isPresented: $showsDeleteConfirmation
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        Task { await model.deleteSelectedSession() }
      }
    } message: {
      Text(
        "The session will be removed from Hardware Controller. Backups or storage snapshots may retain copies."
      )
    }
  }

  private var archiveList: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("History")
              .font(.title2.weight(.semibold))
            Text("Private on this Mac")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Menu("Import", systemImage: "square.and.arrow.down") {
            Button("Audio Recording…") {
              beginAudioImport()
            }
            .accessibilityIdentifier("voice_history_import_audio")
            Button("Voice History Archive…") {
              beginArchiveImport()
            }
            .accessibilityIdentifier("voice_history_import_archive")
          }
          .menuStyle(.borderlessButton)
          .help("Import audio or a Voice History archive")
          .disabled(model.work.isBusy)
          .accessibilityLabel("Import into Voice History")
          .accessibilityIdentifier("voice_history_import")
          Button {
            Task { await model.load() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("Refresh History")
          .disabled(model.work.isBusy)
          .accessibilityIdentifier("voice_history_refresh")
        }

        TextField("Search every text stage", text: $model.searchQuery)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("voice_history_search")

        if model.work == .importing {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text(model.work.title)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .accessibilityIdentifier("voice_history_import_progress")
        }

        if let error = model.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(StudioDesign.warning)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("voice_history_archive_issue")
        }
      }
      .padding(16)

      Divider()

      if model.sessions.isEmpty, model.work != .loading {
        ContentUnavailableView(
          model.searchQuery.isEmpty ? "No Voice History" : "No Results",
          systemImage: "waveform",
          description: Text(
            model.searchQuery.isEmpty
              ? "Voice sessions and imported recordings will appear here."
              : "Try a word from Raw, Formatted, Delivered, or corrected text."
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 3) {
            ForEach(model.sessions) { session in
              Button {
                model.select(sessionID: session.id)
              } label: {
                VoiceHistoryRow(session: session)
                  .padding(.horizontal, 10)
                  .padding(.vertical, 4)
                  .background(
                    session.id == model.selectedSessionID
                      ? StudioDesign.accent.opacity(0.13) : .clear,
                    in: RoundedRectangle(
                      cornerRadius: StudioDesign.compactCornerRadius
                    )
                  )
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier(
                "voice_history_session_\(session.id.uuidString)"
              )
            }
          }
          .padding(8)
        }
        .accessibilityLabel("Voice sessions")
      }
    }
    .frame(width: 320)
  }

  @ViewBuilder
  private var detail: some View {
    if let session = model.selectedSession {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          detailHeader(session)

          if let error = model.errorMessage {
            NoticeBanner(message: error, dismiss: model.clearMessage)
          } else if let notice = model.notice {
            VoiceHistorySuccessBanner(
              message: notice,
              dismiss: model.clearMessage
            )
          }

          playbackCard(session)
          resultCard(session)
          correctionCard
          actionsCard(session)
        }
        .padding(28)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, alignment: .top)
      }
      .scrollIndicators(.hidden)
    } else {
      ContentUnavailableView(
        "Select a Voice Session",
        systemImage: "waveform.badge.magnifyingglass",
        description: Text(
          "Inspect its audio, text stages, provenance, and recovery actions."
        )
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func detailHeader(
    _ session: VoiceSessionHistoryItem
  ) -> some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 9) {
          Text(
            session.document.endedAt.formatted(
              date: .abbreviated,
              time: .shortened
            )
          )
          .font(.largeTitle.weight(.semibold))
          if session.isPinned {
            StatusPill(
              title: "Pinned",
              systemImage: "pin.fill",
              color: StudioDesign.accent
            )
          }
          if session.recoveryKind != nil {
            StatusPill(
              title: "Recovered",
              systemImage: "arrow.clockwise",
              color: StudioDesign.warning
            )
          }
        }
        Text(sessionSubtitle(session))
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        Task { await model.togglePinned() }
      } label: {
        Label(
          session.isPinned ? "Unpin" : "Pin",
          systemImage: session.isPinned ? "pin.slash" : "pin"
        )
      }
      .disabled(model.work.isBusy)
      .accessibilityIdentifier("voice_history_pin")
    }
  }

  @ViewBuilder
  private func playbackCard(
    _ session: VoiceSessionHistoryItem
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Retained audio", systemImage: "waveform")
        .font(.headline)

      if session.audioArtifactURL == nil {
        Text(audioAvailabilityText(session))
          .foregroundStyle(.secondary)
      } else {
        let spans = playbackSpans(session)
        if spans.isEmpty {
          Text("No timed transcript spans are available.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(Array(spans.enumerated()), id: \.offset) { index, span in
            Button {
              if model.isPlaying {
                model.stopPlayback()
              } else {
                model.play(span)
              }
            } label: {
              HStack(spacing: 12) {
                Image(
                  systemName: model.isPlaying
                    ? "stop.fill" : "play.fill"
                )
                VStack(alignment: .leading, spacing: 2) {
                  Text(span.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                  Text(spanTime(span))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer()
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
              "Play audio from \(spanTime(span))"
            )
            .accessibilityIdentifier("voice_history_play_span_\(index)")
          }
        }
      }
    }
    .padding(18)
    .studioCard()
  }

  private func audioAvailabilityText(
    _ session: VoiceSessionHistoryItem
  ) -> String {
    let prefix: String
    switch session.audioExpirationReason {
    case .ageLimit:
      prefix = "Audio expired after reaching its age limit."
    case .artifactLimit:
      prefix = "Audio expired after reaching the recording limit."
    case .byteLimit:
      prefix = "Audio expired after reaching the storage-size limit."
    case .lowDisk:
      prefix = "Audio expired to recover low disk space."
    case .recoveryLimit:
      prefix = "Recovered audio expired after 24 hours."
    case nil:
      prefix = "Audio is unavailable."
    }
    return "\(prefix) Transcript evidence remains searchable."
  }

  private func playbackSpans(
    _ session: VoiceSessionHistoryItem
  ) -> [VoiceHistoryTimedSpan] {
    let timedSpans = session.results
      .filter { $0.stage == .raw }
      .flatMap(\.timedSpans)
    guard timedSpans.isEmpty,
      let duration = session.audioDurationMilliseconds,
      duration > 0
    else {
      return timedSpans
    }
    return [
      VoiceHistoryTimedSpan(
        startMilliseconds: 0,
        endMilliseconds: duration,
        text: session.recoveryKind == nil
          ? "Complete recording" : "Recovered audio"
      )
    ]
  }

  private func resultCard(
    _ session: VoiceSessionHistoryItem
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Text evidence")
          .font(.headline)
        Spacer()
        if let firstResult = session.results.first {
          Picker(
            "Result",
            selection: Binding(
              get: {
                model.selectedResultID ?? firstResult.id
              },
              set: { resultID in
                model.select(resultID: resultID)
              }
            )
          ) {
            ForEach(session.results) { result in
              Text(resultTitle(result)).tag(result.id)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 230)
          .accessibilityLabel("Text result")
          .accessibilityIdentifier("voice_history_result_picker")
        }
      }

      if let result = model.selectedResult {
        Text(result.text.isEmpty ? "No text was delivered." : result.text)
          .font(.body)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
          .background(
            .primary.opacity(0.045),
            in: RoundedRectangle(
              cornerRadius: StudioDesign.compactCornerRadius
            ))

        LazyVGrid(
          columns: [
            GridItem(.adaptive(minimum: 92), alignment: .leading)
          ],
          alignment: .leading,
          spacing: 10
        ) {
          evidenceLabel("Stage", value: result.stage.title)
          evidenceLabel("Source", value: result.origin.title)
          evidenceLabel(
            "From",
            value: sourceTitle(result, in: session)
          )
          if let style = result.style {
            evidenceLabel("Style", value: style.kind.title)
          }
          if let provider = result.provider {
            evidenceLabel("Provider", value: provider.title)
          }
          if let modelIdentifier = result.modelIdentifier {
            evidenceLabel("Model", value: modelIdentifier)
          }
          if let promptRevision = result.promptRevision {
            evidenceLabel("Prompt", value: "r\(promptRevision)")
          }
        }
        .id(result.id)
        .accessibilityElement(children: .combine)

        if let failure = result.deliveryFailure {
          Label(failure, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(StudioDesign.warning)
        }
      }
    }
    .padding(18)
    .studioCard()
  }

  private var correctionCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Correction")
            .font(.headline)
          Text("Saving creates a new result; earlier stages never change.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Save Correction") {
          Task { await model.saveCorrection() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          model.work.isBusy
            || model.correctionDraft.trimmingCharacters(
              in: .whitespacesAndNewlines
            ).isEmpty
        )
        .accessibilityIdentifier("voice_history_save_correction")
      }

      TextEditor(text: $model.correctionDraft)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(10)
        .frame(minHeight: 110)
        .background(
          .primary.opacity(0.045),
          in: RoundedRectangle(
            cornerRadius: StudioDesign.compactCornerRadius
          )
        )
        .accessibilityLabel("Corrected text")
        .accessibilityIdentifier("voice_history_correction")
    }
    .padding(18)
    .studioCard()
  }

  private func actionsCard(
    _ session: VoiceSessionHistoryItem
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Reuse")
        .font(.headline)

      HStack(spacing: 10) {
        Button("Copy", systemImage: "doc.on.doc") {
          copySelectedText()
        }
        .disabled(model.selectedResult?.text.isEmpty != false)
        Button("Insert in 3 Seconds", systemImage: "text.cursor") {
          Task { await model.redeliver() }
        }
        .disabled(
          model.work.isBusy
            || model.selectedResult?.text.isEmpty != false
        )
        .accessibilityIdentifier("voice_history_redeliver")
        Button("Retranscribe", systemImage: "waveform.badge.magnifyingglass") {
          Task { await model.retranscribe() }
        }
        .disabled(
          model.work.isBusy || session.audioArtifactURL == nil
        )
        .accessibilityIdentifier("voice_history_retranscribe")
      }
      .buttonStyle(.bordered)

      HStack(spacing: 10) {
        Picker("Style", selection: $model.selectedStyle) {
          ForEach(VoiceStyleKind.allCases, id: \.self) { style in
            Text(style.title).tag(VoiceStyle(kind: style))
          }
        }
        .frame(maxWidth: 220)
        .accessibilityIdentifier("voice_history_style")
        Button("Reformat", systemImage: "text.alignleft") {
          Task { await model.reformat() }
        }
        .disabled(model.selectedResult?.text.isEmpty != false)
        .accessibilityIdentifier("voice_history_reformat")
        Spacer()
        Button("Export…", systemImage: "square.and.arrow.up") {
          beginExport(session)
        }
        .accessibilityIdentifier("voice_history_export")
        Button("Delete…", systemImage: "trash", role: .destructive) {
          showsDeleteConfirmation = true
        }
        .accessibilityIdentifier("voice_history_delete")
      }
      .buttonStyle(.bordered)
      .disabled(model.work.isBusy)

      if model.work != .idle {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(model.work.title)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("voice_history_progress")
      }
    }
    .padding(18)
    .studioCard()
  }

  private func evidenceLabel(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption)
        .lineLimit(1)
    }
  }

  private func sessionSubtitle(
    _ session: VoiceSessionHistoryItem
  ) -> String {
    let source = session.sourceTitle
    let duration =
      session.audioDurationMilliseconds.map {
        String(format: "%.1f sec", Double($0) / 1_000)
      } ?? "No audio"
    return "\(source) · \(duration) · \(session.document.deliveryOutcome.title)"
  }

  private func resultTitle(_ result: VoiceHistoryResult) -> String {
    let count = model.selectedSession?.results
      .filter { $0.stage == result.stage }
      .firstIndex(of: result)
      .map { $0 + 1 }
    return count.map { "\(result.stage.title) \($0)" }
      ?? result.stage.title
  }

  private func sourceTitle(
    _ result: VoiceHistoryResult,
    in session: VoiceSessionHistoryItem
  ) -> String {
    guard let sourceResultID = result.sourceResultID else {
      return "Session"
    }
    return session.results.first(where: { $0.id == sourceResultID })
      .map(resultTitle)
      ?? "Linked result"
  }

  private func spanTime(_ span: VoiceHistoryTimedSpan) -> String {
    String(
      format: "%.1f–%.1f sec",
      Double(span.startMilliseconds) / 1_000,
      Double(span.endMilliseconds) / 1_000
    )
  }

  private func copySelectedText() {
    guard let text = model.selectedResult?.text, !text.isEmpty else {
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func beginExport(_ session: VoiceSessionHistoryItem) {
    let panel = NSSavePanel()
    panel.title = "Export Voice Session"
    panel.nameFieldStringValue =
      "voice_\(session.id.uuidString.prefix(8).lowercased()).voice_history"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else {
      return
    }
    Task { await model.exportSelectedSession(to: destination) }
  }

  private func beginAudioImport() {
    let panel = NSOpenPanel()
    panel.title = "Import Audio Recording"
    panel.allowedContentTypes = [.audio]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let sourceURL = panel.url else {
      return
    }
    Task { await model.importAudio(from: sourceURL) }
  }

  private func beginArchiveImport() {
    let panel = NSOpenPanel()
    panel.title = "Import Voice History Archive"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    guard panel.runModal() == .OK, let sourceURL = panel.url else {
      return
    }
    Task { await model.importArchive(from: sourceURL) }
  }
}

private struct VoiceHistoryRow: View {
  let session: VoiceSessionHistoryItem

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(session.document.endedAt, style: .time)
          .font(.headline)
        Spacer()
        if session.isPinned {
          Image(systemName: "pin.fill")
            .foregroundStyle(StudioDesign.accent)
        }
      }
      Text(
        session.results.preferredReusableResult?.text
          ?? (session.recoveryKind == nil
            ? "No text" : "Ready to retranscribe")
      )
      .font(.subheadline)
      .lineLimit(2)
      HStack(spacing: 5) {
        Text(session.sourceTitle)
        Text("·")
        Text(session.document.deliveryOutcome.title)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 5)
  }
}

private struct VoiceHistorySuccessBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(StudioDesign.accent)
      Text(message)
        .font(.callout)
      Spacer()
      Button("Dismiss", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .padding(14)
    .studioCard()
  }
}

extension VoiceHistoryTextStage {
  fileprivate var title: String {
    switch self {
    case .raw: "Raw"
    case .edited: "Edited"
    case .formatted: "Formatted"
    case .delivered: "Delivered"
    case .corrected: "Corrected"
    }
  }
}

extension VoiceHistoryResultOrigin {
  fileprivate var title: String {
    switch self {
    case .capture: "Capture"
    case .spokenEdits: "Spoken edits"
    case .formatting: "Formatting"
    case .delivery: "Delivery"
    case .correction: "User correction"
    case .retranscription: "Retranscription"
    case .reformatting: "Reformat"
    case .redelivery: "Re-delivery"
    case .audioImport: "Audio import"
    }
  }
}

extension VoiceStyleKind {
  fileprivate var title: String {
    switch self {
    case .natural: "Natural"
    case .casualMessage: "Casual Message"
    case .formal: "Formal"
    case .technical: "Technical"
    case .verbatim: "Verbatim"
    }
  }
}

extension LocalAIProviderKind {
  fileprivate var title: String {
    switch self {
    case .appleOnDevice: "Apple On-Device"
    case .ollama: "Ollama"
    }
  }
}

extension VoiceSessionDeliveryOutcome {
  fileprivate var title: String {
    switch self {
    case .inserted: "Inserted"
    case .failed: "Needs recovery"
    case .notAttempted: "Not delivered"
    }
  }
}

extension VoiceSessionHistoryItem {
  fileprivate var sourceTitle: String {
    if recoveryKind != nil {
      return "Recovered audio"
    }
    if document.inputKind == .importedAudio {
      return "Imported recording"
    }
    return document.targetApplicationName ?? "Unknown app"
  }
}

extension VoiceHistoryWork {
  fileprivate var title: String {
    switch self {
    case .idle: "Ready"
    case .loading: "Refreshing History…"
    case .importing: "Importing and transcribing locally…"
    case .restoringArchive: "Restoring Voice History…"
    case .correcting: "Saving correction…"
    case .retranscribing: "Retranscribing locally…"
    case .reformatting: "Formatting locally…"
    case .redelivering: "Waiting for the target cursor…"
    case .exporting: "Exporting session…"
    case .deleting: "Deleting session…"
    case .pinning: "Updating pin…"
    }
  }
}
