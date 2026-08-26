import AVFoundation
import Foundation
import HardwareControllerCore
import HardwareControllerMac
import Testing

@testable import HardwareControllerApp

@MainActor
struct VoiceHistoryModelTest {
  @Test
  func loadSearchAndCorrectionFollowImmutableArchiveResults()
    async throws
  {
    let fixture = try HistoryModelFixture()
    defer { fixture.remove() }
    try await fixture.storeSession()
    let model = fixture.model()

    await model.load()
    let originalCount = try #require(model.selectedSession?.results.count)
    model.correctionDraft = "Corrected history text."
    await model.saveCorrection()

    #expect(model.selectedSession?.results.count == originalCount + 1)
    #expect(model.selectedResult?.stage == .corrected)
    #expect(model.correctionDraft == "Corrected history text.")
    #expect(model.notice == "Correction saved as a new result.")

    model.searchQuery = "corrected history"
    await model.load(query: model.searchQuery)
    #expect(model.sessions.map(\.id) == [fixture.sessionID])
    await model.load(query: "missing phrase")
    #expect(model.sessions.isEmpty)
  }

  @Test
  func timedSpanUsesTheRetainedArtifactThroughThePlayer() async throws {
    let fixture = try HistoryModelFixture()
    defer { fixture.remove() }
    try await fixture.storeSession(withAudio: true)
    let player = HistoryModelPlayer()
    let model = fixture.model(player: player)
    await model.load()
    let span = try #require(
      model.selectedSession?.results.first?.timedSpans.first
    )

    model.play(span)

    #expect(player.playedSpans == [span])
    #expect(model.isPlaying)
  }

  @Test
  func newerSearchCannotBeReplacedByAnOlderSlowResult() async {
    let history = RacingHistoryRepository()
    let model = VoiceHistoryModel(
      history: history,
      service: HistoryModelServiceStub()
    )

    let slow = Task { await model.load(query: "slow") }
    await history.waitUntilSlowSearchStarts()
    let fast = Task { await model.load(query: "fast") }
    await fast.value
    await history.finishSlowSearch()
    await slow.value

    #expect(model.sessions.map(\.document.rawText) == ["fast"])
  }

  @Test
  func demoHistoryPreservesItsImmutableResultGraph() async throws {
    let presentation = VoiceHistoryPresentation(
      arguments: ["HardwareController", "--demo"],
      localAISettings: .default
    )

    await presentation.model.load()

    let results = try #require(
      presentation.model.selectedSession?.results
    )
    #expect(results.count == 3)
    #expect(results[1].sourceResultID == results[0].id)
    #expect(results[2].sourceResultID == results[1].id)
    #expect(results[1].provider == .appleOnDevice)
    #expect(presentation.model.sessions[1].audioExpiredAt != nil)
    #expect(
      presentation.model.sessions[1].audioExpirationReason == .byteLimit
    )
    #expect(presentation.model.sessions.count == 3)
    #expect(
      presentation.model.sessions[2].recoveryKind == .interruptedCapture
    )
    #expect(
      presentation.model.sessions[2].audioExpirationReason == .recoveryLimit
    )
    presentation.model.select(
      sessionID: presentation.model.sessions[2].id
    )
    #expect(presentation.model.selectedResult?.stage == .raw)
    #expect(presentation.model.selectedResult?.text.isEmpty == true)
  }

  @Test
  func applyingRetentionRefreshesExpiredAudioWithoutLosingText()
    async throws
  {
    let fixture = try HistoryModelFixture()
    defer { fixture.remove() }
    try await fixture.storeSession(withAudio: true)
    let model = fixture.model()
    await model.load()
    #expect(model.selectedSession?.audioArtifactURL != nil)

    await model.applyRetention(
      VoiceHistoryRetentionSettings(
        maximumAgeDays: nil,
        maximumAudioBytes: nil,
        maximumArtifactCount: 0
      )
    )

    #expect(model.selectedSession?.audioArtifactURL == nil)
    #expect(model.selectedSession?.audioExpirationReason == .artifactLimit)
    #expect(model.selectedSession?.rawText == "searchable raw text")
    #expect(model.notice?.contains("1 audio recording") == true)
  }

  @Test
  func loadSurfacesSanitizedRecoveryEvidence() async {
    let model = VoiceHistoryModel(
      history: RacingHistoryRepository(),
      service: HistoryModelServiceStub(),
      recoveryManager: RecoveryIssueManager()
    )

    await model.load()

    #expect(
      model.errorMessage
        == "A damaged Voice History record was isolated. Other History remains available."
    )
  }
}

private struct RecoveryIssueManager: VoiceSessionHistoryRecoveryManaging {
  func latestRecoveryReport() -> VoiceHistoryRecoveryReport? {
    VoiceHistoryRecoveryReport(
      completedAt: .distantPast,
      completedActions: [],
      issues: [.invalidSessionRecord]
    )
  }
}

private actor RacingHistoryRepository: VoiceSessionHistoryAccessing {
  private var slowContinuation: CheckedContinuation<Void, Never>?
  private var startObservers: [CheckedContinuation<Void, Never>] = []
  private var didStartSlowSearch = false

  func recentSessions(limit: Int) async throws
    -> [VoiceSessionHistoryItem]
  {
    []
  }

  func searchSessions(query: String, limit: Int) async throws
    -> [VoiceSessionHistoryItem]
  {
    if query == "slow" {
      didStartSlowSearch = true
      let observers = startObservers
      startObservers.removeAll()
      for observer in observers {
        observer.resume()
      }
      await withCheckedContinuation { continuation in
        slowContinuation = continuation
      }
    }
    return [Self.item(text: query)]
  }

  func session(id: UUID) async throws -> VoiceSessionHistoryItem? {
    nil
  }

  func appendResult(_ result: VoiceHistoryResult) async throws {}
  func setPinned(sessionID: UUID, isPinned: Bool) async throws {}
  func deleteSession(id: UUID) async throws {}

  func waitUntilSlowSearchStarts() async {
    guard !didStartSlowSearch else {
      return
    }
    await withCheckedContinuation { continuation in
      startObservers.append(continuation)
    }
  }

  func finishSlowSearch() {
    slowContinuation?.resume()
    slowContinuation = nil
  }

  private nonisolated static func item(
    text: String
  ) -> VoiceSessionHistoryItem {
    VoiceSessionHistoryItem(
      document: VoiceSessionDocument(
        id: UUID(),
        startedAt: .distantPast,
        endedAt: .distantPast,
        rawText: text,
        editedText: text,
        formattedText: text,
        deliveredText: text,
        targetApplicationName: nil,
        deliveryOutcome: .inserted
      ),
      audioArtifactURL: nil
    )
  }
}

private struct HistoryModelServiceStub: VoiceHistoryServicing {
  func correct(
    sessionID: UUID,
    sourceResultID: UUID,
    text: String
  ) async throws -> VoiceHistoryResult {
    throw VoiceHistoryServiceError.sessionNotFound
  }

  func retranscribe(
    sessionID: UUID
  ) async throws -> VoiceHistoryResult {
    throw VoiceHistoryServiceError.sessionNotFound
  }

  func reformat(
    sessionID: UUID,
    sourceResultID: UUID,
    style: VoiceStyle
  ) async throws -> VoiceHistoryResult {
    throw VoiceHistoryServiceError.sessionNotFound
  }

  func redeliver(
    sessionID: UUID,
    sourceResultID: UUID
  ) async throws -> VoiceHistoryResult {
    throw VoiceHistoryServiceError.sessionNotFound
  }
}

private final class HistoryModelFixture: @unchecked Sendable {
  let root: URL
  let history: SQLiteVoiceSessionHistory
  let sessionID = UUID()

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "history_model_\(UUID().uuidString)")
    history = try SQLiteVoiceSessionHistory(rootDirectory: root)
  }

  func storeSession(withAudio: Bool = false) async throws {
    let document = VoiceSessionDocument(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 1_000),
      endedAt: Date(timeIntervalSince1970: 1_001),
      rawText: "searchable raw text",
      editedText: "searchable edited text",
      formattedText: "Searchable formatted text.",
      deliveredText: "Searchable formatted text.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted
    )
    history.begin(sessionID: sessionID, startedAt: document.startedAt)
    if withAudio {
      history.append(try historyModelAudioFixture())
    }
    try await history.complete(document)
  }

  @MainActor
  func model(
    player: (any VoiceHistoryAudioPlaying)? = nil
  ) -> VoiceHistoryModel {
    VoiceHistoryModel(
      history: history,
      service: VoiceHistoryService(
        history: history,
        transcriber: HistoryModelTranscriber(),
        reformatter: HistoryModelReformatter(),
        redeliverer: HistoryModelRedeliverer()
      ),
      retentionManager: history,
      exporter: HistoryModelExporter(),
      player: player
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct HistoryModelTranscriber: VoiceHistoryAudioTranscribing {
  func transcribe(
    audioURL: URL,
    locale: Locale
  ) async throws -> VoiceHistoryTranscription {
    VoiceHistoryTranscription(text: "Retranscribed.", spans: [])
  }
}

private struct HistoryModelReformatter: VoiceHistoryReformatting {
  func reformat(
    text: String,
    sessionID: UUID,
    style: VoiceStyle
  ) async throws -> VoiceHistoryReformat {
    VoiceHistoryReformat(
      text: text,
      document: try VoiceFormattedDocumentBuilder().build(
        formattedText: text,
        rawText: text,
        style: style
      )
    )
  }
}

private struct HistoryModelRedeliverer: VoiceHistoryRedelivering {
  func redeliver(_ text: String) async throws {}
}

private struct HistoryModelExporter: VoiceHistoryExporting {
  func export(
    _ session: VoiceSessionHistoryItem,
    to destination: URL
  ) async throws {}
}

@MainActor
private final class HistoryModelPlayer: VoiceHistoryAudioPlaying {
  private(set) var isPlaying = false
  private(set) var playedSpans: [VoiceHistoryTimedSpan] = []

  func play(
    audioURL: URL,
    span: VoiceHistoryTimedSpan
  ) throws {
    playedSpans.append(span)
    isPlaying = true
  }

  func stop() {
    isPlaying = false
  }
}

private func historyModelAudioFixture() throws -> CapturedAudioBuffer {
  guard
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    ),
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: 1_600
    )
  else {
    throw MicrophoneCaptureError.invalidBuffer("Fixture failed.")
  }
  buffer.frameLength = 1_600
  return try CapturedAudioBuffer(copying: buffer)
}
