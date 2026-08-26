import Foundation
import HardwareControllerCore
import HardwareControllerMac
import Observation

enum VoiceHistoryWork: Equatable {
  case idle
  case loading
  case correcting
  case retranscribing
  case reformatting
  case redelivering
  case exporting
  case deleting
  case pinning

  var isBusy: Bool { self != .idle }
}

@MainActor
@Observable
private final class VoiceHistoryPlaybackState {
  var isPlaying = false
}

/// Owns History presentation state without weakening immutable archive semantics.
@MainActor
@Observable
final class VoiceHistoryModel {
  private(set) var sessions: [VoiceSessionHistoryItem] = []
  var selectedSessionID: UUID?
  var selectedResultID: UUID?
  var searchQuery = ""
  var correctionDraft = ""
  var selectedStyle = VoiceStyle.natural
  private(set) var work = VoiceHistoryWork.idle
  private(set) var errorMessage: String?
  private(set) var notice: String?
  var isPlaying: Bool { playbackState.isPlaying }

  @ObservationIgnored private let history: any VoiceSessionHistoryAccessing
  @ObservationIgnored private let service: any VoiceHistoryServicing
  @ObservationIgnored private let exporter: any VoiceHistoryExporting
  @ObservationIgnored private let player: any VoiceHistoryAudioPlaying
  @ObservationIgnored private let playbackState: VoiceHistoryPlaybackState
  @ObservationIgnored private var loadGeneration: UInt64 = 0

  init(
    history: any VoiceSessionHistoryAccessing,
    service: any VoiceHistoryServicing,
    exporter: any VoiceHistoryExporting = VoiceHistoryExporter(),
    player: (any VoiceHistoryAudioPlaying)? = nil
  ) {
    self.history = history
    self.service = service
    self.exporter = exporter
    let playbackState = VoiceHistoryPlaybackState()
    self.playbackState = playbackState
    if let player {
      self.player = player
    } else {
      self.player = VoiceHistoryAudioPlayer { isPlaying in
        playbackState.isPlaying = isPlaying
      }
    }
  }

  var selectedSession: VoiceSessionHistoryItem? {
    sessions.first { $0.id == selectedSessionID }
  }

  var selectedResult: VoiceHistoryResult? {
    guard let selectedSession else {
      return nil
    }
    return selectedSession.results.first { $0.id == selectedResultID }
      ?? selectedSession.results.preferredReusableResult
  }

  func load(query: String? = nil) async {
    guard !work.isBusy || work == .loading else {
      return
    }
    loadGeneration &+= 1
    let generation = loadGeneration
    work = .loading
    errorMessage = nil
    do {
      let value = query ?? searchQuery
      let loadedSessions = try await history.searchSessions(
        query: value,
        limit: 250
      )
      guard generation == loadGeneration else {
        return
      }
      sessions = loadedSessions
      reconcileSelection()
    } catch {
      guard generation == loadGeneration else {
        return
      }
      errorMessage = message(for: error)
    }
    if generation == loadGeneration {
      work = .idle
    }
  }

  func select(sessionID: UUID?) {
    guard selectedSessionID != sessionID else {
      return
    }
    selectedSessionID = sessionID
    selectedResultID =
      selectedSession?.results
      .preferredReusableResult?.id
    correctionDraft =
      selectedSession?.results
      .preferredReusableResult?.text ?? ""
    notice = nil
    errorMessage = nil
    stopPlayback()
  }

  func select(resultID: UUID) {
    selectedResultID = resultID
    if let selectedResult {
      correctionDraft = selectedResult.text
    }
  }

  func saveCorrection() async {
    guard
      let selectedSessionID,
      let selectedResultID
    else {
      return
    }
    await perform(.correcting) {
      _ = try await service.correct(
        sessionID: selectedSessionID,
        sourceResultID: selectedResultID,
        text: correctionDraft
      )
      notice = "Correction saved as a new result."
    }
  }

  func retranscribe() async {
    guard let selectedSessionID else {
      return
    }
    await perform(.retranscribing) {
      _ = try await service.retranscribe(sessionID: selectedSessionID)
      notice = "Retranscription saved as a new Raw result."
    }
  }

  func reformat() async {
    guard
      let selectedSessionID,
      let selectedResultID
    else {
      return
    }
    await perform(.reformatting) {
      _ = try await service.reformat(
        sessionID: selectedSessionID,
        sourceResultID: selectedResultID,
        style: selectedStyle
      )
      notice = "Reformatted text saved as a new result."
    }
  }

  func redeliver() async {
    guard
      let selectedSessionID,
      let selectedResultID
    else {
      return
    }
    notice = "Switch to an empty text cursor. Inserting in 3 seconds…"
    await perform(.redelivering) {
      _ = try await service.redeliver(
        sessionID: selectedSessionID,
        sourceResultID: selectedResultID
      )
      notice = "Text inserted and recorded as a new delivery result."
    }
  }

  func togglePinned() async {
    guard let session = selectedSession else {
      return
    }
    await perform(.pinning) {
      try await history.setPinned(
        sessionID: session.id,
        isPinned: !session.isPinned
      )
      notice = session.isPinned ? "Session unpinned." : "Session pinned."
    }
  }

  func deleteSelectedSession() async {
    guard let selectedSessionID else {
      return
    }
    await perform(.deleting) {
      try await history.deleteSession(id: selectedSessionID)
      notice = "Session and retained audio deleted."
      self.selectedSessionID = nil
      selectedResultID = nil
      correctionDraft = ""
    }
  }

  func exportSelectedSession(to destination: URL) async {
    guard let selectedSession else {
      return
    }
    await perform(.exporting) {
      try await exporter.export(selectedSession, to: destination)
      notice = "Session exported."
    }
  }

  func play(_ span: VoiceHistoryTimedSpan) {
    guard let audioURL = selectedSession?.audioArtifactURL else {
      errorMessage = "This session no longer has retained audio."
      return
    }
    do {
      try player.play(audioURL: audioURL, span: span)
      playbackState.isPlaying = player.isPlaying
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  func stopPlayback() {
    player.stop()
    playbackState.isPlaying = false
  }

  func clearMessage() {
    errorMessage = nil
    notice = nil
  }

  private func perform(
    _ operation: VoiceHistoryWork,
    action: () async throws -> Void
  ) async {
    guard !work.isBusy else {
      return
    }
    work = operation
    errorMessage = nil
    do {
      try await action()
      let retainedNotice = notice
      await refreshSelection()
      notice = retainedNotice
    } catch {
      errorMessage = message(for: error)
    }
    work = .idle
  }

  private func refreshSelection() async {
    let retainedSessionID = selectedSessionID
    do {
      sessions = try await history.searchSessions(
        query: searchQuery,
        limit: 250
      )
      selectedSessionID = retainedSessionID
      reconcileSelection()
      selectedResultID = selectedSession?.results.last?.id
      correctionDraft =
        selectedSession?.results
        .preferredReusableResult?.text ?? ""
    } catch {
      errorMessage = message(for: error)
    }
  }

  private func reconcileSelection() {
    if let selectedSessionID,
      sessions.contains(where: { $0.id == selectedSessionID })
    {
      if selectedResult == nil {
        selectedResultID =
          selectedSession?.results
          .preferredReusableResult?.id
      }
      return
    }
    selectedSessionID = sessions.first?.id
    selectedResultID =
      sessions.first?.results
      .preferredReusableResult?.id
    correctionDraft =
      sessions.first?.results
      .preferredReusableResult?.text ?? ""
  }

  private func message(for error: any Error) -> String {
    if let localized = error as? any LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    switch error {
    case VoiceHistoryServiceError.audioUnavailable:
      return "This session no longer has retained audio."
    case VoiceHistoryServiceError.noReusableText:
      return "This session has no reusable text."
    case VoiceHistoryServiceError.invalidCorrection:
      return "A correction cannot be empty."
    case VoiceHistoryServiceError.sessionNotFound:
      return "This session no longer exists."
    case TranscriptionFailure.focusChanged,
      TranscriptionFailure.noFocusedTextField:
      return "Focus an empty text cursor and try re-delivery again."
    case TranscriptionFailure.processChanged:
      return "The target application changed before re-delivery."
    case TranscriptionFailure.secureTextField:
      return "Voice History never inserts into secure text fields."
    case TranscriptionFailure.caretChanged:
      return "The text cursor changed before re-delivery."
    default:
      return error.localizedDescription
    }
  }
}

/// Composes one query/action graph for the app window without sharing UI state.
@MainActor
struct VoiceHistoryPresentation {
  let model: VoiceHistoryModel
  let reformatter: LocalAIVoiceHistoryReformatter

  init(
    arguments: [String],
    localAISettings: LocalAISettings
  ) {
    let history: any VoiceSessionHistoryAccessing
    if arguments.contains("--demo") {
      history = DemoVoiceSessionHistory()
    } else {
      do {
        history = try SQLiteVoiceSessionHistory.applicationSupportHistory()
      } catch let failure as VoiceSessionHistoryError {
        history = UnavailableVoiceSessionHistory(failure: failure)
      } catch {
        history = UnavailableVoiceSessionHistory(
          failure: .storageUnavailable(
            "Voice History could not open its local storage."
          )
        )
      }
    }
    let reformatter = LocalAIVoiceHistoryReformatter(
      settings: localAISettings
    )
    self.reformatter = reformatter
    model = VoiceHistoryModel(
      history: history,
      service: VoiceHistoryService(
        history: history,
        transcriber: AppleVoiceHistoryAudioTranscriber(),
        reformatter: reformatter,
        redeliverer: FocusedVoiceHistoryRedeliverer()
      )
    )
  }
}

/// Supplies deterministic no-write History rows for packaged UI verification.
private actor DemoVoiceSessionHistory: VoiceSessionHistoryAccessing {
  private var items: [VoiceSessionHistoryItem]

  init() {
    let firstID = UUID()
    let secondID = UUID()
    items = [
      Self.item(
        id: firstID,
        endedAt: Date().addingTimeInterval(-280),
        target: "Notes",
        raw: "first install git then run bash version",
        formatted: "1. Install Git.\n2. Run `bash --version`.",
        style: .technical,
        pinned: true
      ),
      Self.item(
        id: secondID,
        endedAt: Date().addingTimeInterval(-3_700),
        target: "Messages",
        raw: "send the revised plan tomorrow",
        formatted: "send the revised plan tomorrow.",
        style: .casualMessage,
        pinned: false
      ),
    ]
  }

  func recentSessions(limit: Int) async throws
    -> [VoiceSessionHistoryItem]
  {
    Array(items.prefix(limit))
  }

  func searchSessions(query: String, limit: Int) async throws
    -> [VoiceSessionHistoryItem]
  {
    let normalized = query.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).lowercased()
    let matches =
      normalized.isEmpty
      ? items
      : items.filter { item in
        item.results.contains {
          $0.text.lowercased().contains(normalized)
        }
      }
    return Array(matches.prefix(limit))
  }

  func session(id: UUID) async throws -> VoiceSessionHistoryItem? {
    items.first { $0.id == id }
  }

  func appendResult(_ result: VoiceHistoryResult) async throws {
    guard let index = items.firstIndex(where: { $0.id == result.sessionID }) else {
      throw VoiceSessionHistoryError.sessionNotFound
    }
    let item = items[index]
    items[index] = VoiceSessionHistoryItem(
      document: item.document,
      audioArtifactURL: item.audioArtifactURL,
      audioDurationMilliseconds: item.audioDurationMilliseconds,
      isPinned: item.isPinned,
      results: item.results + [result]
    )
  }

  func setPinned(sessionID: UUID, isPinned: Bool) async throws {
    guard let index = items.firstIndex(where: { $0.id == sessionID }) else {
      throw VoiceSessionHistoryError.sessionNotFound
    }
    let item = items[index]
    items[index] = VoiceSessionHistoryItem(
      document: item.document,
      audioArtifactURL: item.audioArtifactURL,
      audioDurationMilliseconds: item.audioDurationMilliseconds,
      isPinned: isPinned,
      results: item.results
    )
  }

  func deleteSession(id: UUID) async throws {
    guard items.contains(where: { $0.id == id }) else {
      throw VoiceSessionHistoryError.sessionNotFound
    }
    items.removeAll { $0.id == id }
  }

  private nonisolated static func item(
    id: UUID,
    endedAt: Date,
    target: String,
    raw: String,
    formatted: String,
    style: VoiceStyle,
    pinned: Bool
  ) -> VoiceSessionHistoryItem {
    let rawID = UUID()
    let formattedID = UUID()
    let document = VoiceSessionDocument(
      id: id,
      startedAt: endedAt.addingTimeInterval(-18),
      endedAt: endedAt,
      rawText: raw,
      editedText: raw,
      formattedText: formatted,
      deliveredText: formatted,
      targetApplicationName: target,
      deliveryOutcome: .inserted
    )
    return VoiceSessionHistoryItem(
      document: document,
      audioArtifactURL: nil,
      audioDurationMilliseconds: 18_000,
      isPinned: pinned,
      results: [
        VoiceHistoryResult(
          id: rawID,
          sessionID: id,
          createdAt: endedAt,
          stage: .raw,
          origin: .capture,
          text: raw,
          sourceResultID: nil,
          timedSpans: [
            VoiceHistoryTimedSpan(
              startMilliseconds: 0,
              endMilliseconds: 18_000,
              text: raw
            )
          ]
        ),
        VoiceHistoryResult(
          id: formattedID,
          sessionID: id,
          createdAt: endedAt,
          stage: .formatted,
          origin: .formatting,
          text: formatted,
          sourceResultID: rawID,
          style: style,
          provider: .appleOnDevice,
          modelIdentifier: "Apple SystemLanguageModel",
          promptRevision: VersionedLocalAIPromptBuilder.currentRevision
        ),
        VoiceHistoryResult(
          sessionID: id,
          createdAt: endedAt,
          stage: .delivered,
          origin: .delivery,
          text: formatted,
          sourceResultID: formattedID,
          deliveryOutcome: .inserted
        ),
      ]
    )
  }
}
