import Foundation
import HardwareControllerCore
import HardwareControllerMac
import Observation

enum VoiceHistoryWork: Equatable {
  case idle
  case loading
  case importing
  case restoringArchive
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
  @ObservationIgnored private let retentionManager: (any VoiceSessionHistoryRetentionManaging)?
  @ObservationIgnored private let recoveryManager: (any VoiceSessionHistoryRecoveryManaging)?
  @ObservationIgnored private let service: any VoiceHistoryServicing
  @ObservationIgnored private let importer: (any VoiceAudioImporting)?
  @ObservationIgnored private let archiveImporter: (any VoiceHistoryArchiveImporting)?
  @ObservationIgnored private let exporter: any VoiceHistoryExporting
  @ObservationIgnored private let player: any VoiceHistoryAudioPlaying
  @ObservationIgnored private let playbackState: VoiceHistoryPlaybackState
  @ObservationIgnored private var loadGeneration: UInt64 = 0

  init(
    history: any VoiceSessionHistoryAccessing,
    service: any VoiceHistoryServicing,
    importer: (any VoiceAudioImporting)? = nil,
    archiveImporter: (any VoiceHistoryArchiveImporting)? = nil,
    retentionManager: (any VoiceSessionHistoryRetentionManaging)? = nil,
    recoveryManager: (any VoiceSessionHistoryRecoveryManaging)? = nil,
    exporter: any VoiceHistoryExporting = VoiceHistoryExporter(),
    player: (any VoiceHistoryAudioPlaying)? = nil
  ) {
    self.history = history
    self.retentionManager = retentionManager
    self.recoveryManager = recoveryManager
    self.service = service
    self.importer = importer
    self.archiveImporter = archiveImporter
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
      ?? selectedSession.results.first
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
      if let report = recoveryManager?.latestRecoveryReport(),
        !report.issues.isEmpty
      {
        errorMessage = recoveryIssueMessage(report.issues)
      } else if let report = retentionManager?.latestRetentionReport(),
        !report.issues.isEmpty
      {
        errorMessage = retentionIssueMessage(report.issues)
      }
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
      ?? selectedSession?.results.first?.id
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

  func importAudio(from sourceURL: URL) async {
    guard let importer else {
      return
    }
    await perform(.importing) {
      let result = try await importer.importAudio(
        from: sourceURL,
        style: selectedStyle
      )
      selectedSessionID = result.sessionID
      switch result.processingOutcome {
      case .formatted:
        notice = "Recording imported, transcribed, and formatted locally."
      case .transcriptOnly:
        notice = "Recording imported and transcribed. Local formatting was unavailable."
      case .audioOnly:
        notice = "Recording imported. Local transcription was unavailable; retry from History."
      }
    }
  }

  func importArchive(from sourceURL: URL) async {
    guard let archiveImporter else {
      return
    }
    await perform(.restoringArchive) {
      let outcome = try await archiveImporter.importArchive(from: sourceURL)
      selectedSessionID = outcome.sessionID
      switch outcome.disposition {
      case .imported:
        notice = "Voice session restored from its local archive."
      case .alreadyPresent:
        notice = "This Voice session is already in History."
      }
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

  func applyRetention(_ settings: VoiceHistoryRetentionSettings) async {
    guard let retentionManager else {
      return
    }
    do {
      let report = try await retentionManager.setRetentionSettings(settings)
      await load()
      if report.issues.isEmpty {
        if report.expired.isEmpty {
          notice = "Voice History storage limits updated."
        } else if report.expired.count == 1 {
          notice =
            "Voice History storage limits updated; 1 audio recording expired."
        } else {
          notice =
            "Voice History storage limits updated; \(report.expired.count) audio recordings expired."
        }
      } else {
        errorMessage =
          "Storage limits were saved, but some protected or unavailable audio could not be reclaimed."
      }
    } catch {
      errorMessage = message(for: error)
    }
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
      selectedResultID =
        selectedSession?.results.preferredReusableResult?.id
        ?? selectedSession?.results.last?.id
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
          ?? selectedSession?.results.first?.id
      }
      return
    }
    selectedSessionID = sessions.first?.id
    selectedResultID =
      sessions.first?.results
      .preferredReusableResult?.id
      ?? sessions.first?.results.first?.id
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

  private func retentionIssueMessage(
    _ issues: [VoiceHistoryRetentionIssue]
  ) -> String {
    if issues.contains(where: {
      if case .lowDiskShortfall = $0 { true } else { false }
    }) {
      return
        "Low disk space remains. Pinned or recovery audio was protected from automatic removal."
    }
    if issues.contains(where: {
      switch $0 {
      case .byteLimitUnmet, .artifactLimitUnmet:
        true
      default:
        false
      }
    }) {
      return
        "Voice History exceeds a storage limit because pinned or recovery audio was protected."
    }
    if issues.contains(where: {
      switch $0 {
      case .missingArtifact, .unreadableArtifactSize, .removalFailed:
        true
      default:
        false
      }
    }) {
      return
        "Some retained audio could not be inspected or fully removed. Other History remains available."
    }
    if let issue = issues.first,
      case .maintenanceUnavailable(let detail) = issue
    {
      return "Voice History cleanup could not finish: \(detail)"
    }
    return "Voice History cleanup could not finish."
  }

  private func recoveryIssueMessage(
    _ issues: [VoiceHistoryRecoveryRuntimeIssue]
  ) -> String {
    if issues.contains(.invalidSessionRecord) {
      return
        "A damaged Voice History record was isolated. Other History remains available."
    }
    if issues.contains(where: {
      if case .databaseRebuilt = $0 { true } else { false }
    }) {
      return
        "A damaged Voice History database was preserved and clean local History was restored."
    }
    if issues.contains(where: {
      if case .actionFailed = $0 { true } else { false }
    }) {
      return
        "Voice History could not finish recovering some audio. It was preserved for the next launch."
    }
    return
      "Unreadable recovery audio was preserved for up to 24 hours. Other History remains available."
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
    self.init(
      arguments: arguments,
      localAISettings: localAISettings,
      history: Self.makeHistory(
        arguments: arguments,
        retentionSettings: .macOSDefault
      )
    )
  }

  init(
    arguments: [String],
    localAISettings: LocalAISettings,
    history: any VoiceSessionHistoryManaging
  ) {
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
      ),
      importer: VoiceAudioImportService(
        history: history,
        transcriber: AppleVoiceHistoryAudioTranscriber(),
        reformatter: reformatter
      ),
      archiveImporter: VoiceHistoryArchiveImporter(history: history),
      retentionManager: history,
      recoveryManager: history
    )
  }

  static func makeHistory(
    arguments: [String],
    retentionSettings: VoiceHistoryRetentionSettings
  ) -> any VoiceSessionHistoryManaging {
    if arguments.contains("--demo") {
      return DemoVoiceSessionHistory()
    }
    do {
      return try SQLiteVoiceSessionHistory.applicationSupportHistory(
        retentionSettings: retentionSettings
      )
    } catch let failure as VoiceSessionHistoryError {
      return UnavailableVoiceSessionHistory(failure: failure)
    } catch {
      return UnavailableVoiceSessionHistory(
        failure: .storageUnavailable(
          "Voice History could not open its local storage."
        )
      )
    }
  }
}

/// Supplies deterministic no-write History rows for packaged UI verification.
private actor DemoVoiceSessionHistory: VoiceSessionHistoryManaging {
  private var items: [VoiceSessionHistoryItem]

  init() {
    let firstID = UUID()
    let secondID = UUID()
    let recoveredID = UUID()
    items = [
      Self.item(
        id: firstID,
        endedAt: Date().addingTimeInterval(-280),
        target: "Notes",
        raw: "first install git then run bash version",
        formatted: "1. Install Git.\n2. Run `bash --version`.",
        style: .technical,
        formattedBlock: VoiceFormattedBlock(
          kind: .orderedList,
          items: ["Install Git.", "Run `bash --version`."],
          evidenceIndices: [0]
        ),
        pinned: true
      ),
      Self.item(
        id: secondID,
        endedAt: Date().addingTimeInterval(-3_700),
        target: "Messages",
        raw: "send the revised plan tomorrow",
        formatted: "send the revised plan tomorrow.",
        style: .casualMessage,
        formattedBlock: VoiceFormattedBlock(
          kind: .paragraph,
          items: ["send the revised plan tomorrow."],
          evidenceIndices: [0]
        ),
        formattingValidationStatus: .sourceFallback,
        pinned: false,
        audioExpirationReason: .byteLimit
      ),
      Self.item(
        id: recoveredID,
        endedAt: Date().addingTimeInterval(-7_400),
        target: nil,
        raw: "",
        formatted: "",
        style: .natural,
        pinned: false,
        audioExpirationReason: .recoveryLimit,
        recoveryKind: .interruptedCapture,
        deliveryOutcome: .notAttempted
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
      audioExpiredAt: item.audioExpiredAt,
      audioExpirationReason: item.audioExpirationReason,
      recoveryKind: item.recoveryKind,
      recoveredAt: item.recoveredAt,
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
      audioExpiredAt: item.audioExpiredAt,
      audioExpirationReason: item.audioExpirationReason,
      recoveryKind: item.recoveryKind,
      recoveredAt: item.recoveredAt,
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

  nonisolated func begin(sessionID: UUID, startedAt: Date) {}
  nonisolated func append(_ audio: CapturedAudioBuffer) {}
  func complete(_ document: VoiceSessionDocument) async throws {}
  func cancel(sessionID: UUID) async {}

  func importAudioSession(
    _ document: VoiceSessionDocument,
    from sourceURL: URL,
    limits: VoiceAudioImportLimits
  ) async throws {
    throw VoiceSessionHistoryError.storageUnavailable(
      "Audio import is unavailable in demo mode."
    )
  }

  func restoreArchive(
    _ session: VoiceSessionHistoryItem
  ) async throws {
    throw VoiceSessionHistoryError.storageUnavailable(
      "Voice History archive import is unavailable in demo mode."
    )
  }

  func setRetentionSettings(
    _ settings: VoiceHistoryRetentionSettings
  ) async throws -> VoiceHistoryRetentionReport {
    VoiceHistoryRetentionReport(
      completedAt: Date(),
      expired: [],
      issues: []
    )
  }

  func reclaimForLowDisk(bytes: Int64) async throws
    -> VoiceHistoryRetentionReport
  {
    VoiceHistoryRetentionReport(
      completedAt: Date(),
      expired: [],
      issues: []
    )
  }

  nonisolated func latestRetentionReport()
    -> VoiceHistoryRetentionReport?
  {
    nil
  }

  nonisolated func latestRecoveryReport()
    -> VoiceHistoryRecoveryReport?
  {
    nil
  }

  private nonisolated static func item(
    id: UUID,
    endedAt: Date,
    target: String?,
    raw: String,
    formatted: String,
    style: VoiceStyle,
    formattedBlock: VoiceFormattedBlock? = nil,
    formattingValidationStatus: VoiceFormattingValidationStatus = .validated,
    pinned: Bool,
    audioExpirationReason: VoiceHistoryAudioExpirationReason? = nil,
    recoveryKind: VoiceHistoryRecoveryKind? = nil,
    deliveryOutcome: VoiceSessionDeliveryOutcome = .inserted
  ) -> VoiceSessionHistoryItem {
    let rawID = UUID()
    let formattedID = UUID()
    let sessionEndedAt =
      recoveryKind == nil
      ? endedAt : endedAt.addingTimeInterval(-86_400)
    let document = VoiceSessionDocument(
      id: id,
      startedAt: sessionEndedAt.addingTimeInterval(-18),
      endedAt: sessionEndedAt,
      rawText: raw,
      editedText: raw,
      formattedText: formatted,
      deliveredText: formatted,
      targetApplicationName: target,
      deliveryOutcome: deliveryOutcome
    )
    return VoiceSessionHistoryItem(
      document: document,
      audioArtifactURL: nil,
      audioDurationMilliseconds: 18_000,
      audioExpiredAt: audioExpirationReason.map { _ in endedAt },
      audioExpirationReason: audioExpirationReason,
      recoveryKind: recoveryKind,
      recoveredAt: recoveryKind.map { _ in sessionEndedAt },
      isPinned: pinned,
      results: [
        VoiceHistoryResult(
          id: rawID,
          sessionID: id,
          createdAt: sessionEndedAt,
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
          createdAt: sessionEndedAt,
          stage: .formatted,
          origin: .formatting,
          text: formatted,
          sourceResultID: rawID,
          style: style,
          provider: .appleOnDevice,
          modelIdentifier: "Apple SystemLanguageModel",
          promptRevision: VersionedLocalAIPromptBuilder.currentRevision,
          formattedDocument: formattedBlock.map { block in
            VoiceFormattedDocument(
              rawText: raw,
              style: style,
              blocks: [block],
              evidence: [
                VoiceFormattingEvidence(
                  rawUTF8StartOffset: 0,
                  rawUTF8EndOffset: raw.utf8.count,
                  provider: .appleOnDevice,
                  modelIdentifier: "Apple SystemLanguageModel",
                  promptRevision: VersionedLocalAIPromptBuilder.currentRevision
                )
              ],
              validationStatus: formattingValidationStatus
            )
          }
        ),
        VoiceHistoryResult(
          sessionID: id,
          createdAt: sessionEndedAt,
          stage: .delivered,
          origin: .delivery,
          text: formatted,
          sourceResultID: formattedID,
          deliveryOutcome: deliveryOutcome
        ),
      ]
    )
  }
}
