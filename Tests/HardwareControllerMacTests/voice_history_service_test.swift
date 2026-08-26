import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct VoiceHistoryServiceTest {
  @Test
  func reuseActionsAppendLinkedResultsWithoutMutatingTheCapture()
    async throws
  {
    let fixture = try HistoryServiceFixture()
    defer { fixture.remove() }
    let original = try await fixture.storeSession(withAudio: true)
    let service = fixture.service()
    let initial = try #require(
      try await fixture.history.session(id: fixture.sessionID)
    )
    let initialSource = try #require(
      initial.results.preferredReusableResult
    )

    let correction = try await service.correct(
      sessionID: fixture.sessionID,
      sourceResultID: initialSource.id,
      text: "Corrected text."
    )
    let retranscription = try await service.retranscribe(
      sessionID: fixture.sessionID
    )
    let reformat = try await service.reformat(
      sessionID: fixture.sessionID,
      sourceResultID: correction.id,
      style: .formal
    )
    let redelivery = try await service.redeliver(
      sessionID: fixture.sessionID,
      sourceResultID: reformat.id
    )

    let stored = try #require(
      try await fixture.history.session(id: fixture.sessionID)
    )
    #expect(stored.document == original)
    #expect(correction.stage == .corrected)
    #expect(correction.origin == .correction)
    #expect(correction.sourceResultID == initialSource.id)
    #expect(retranscription.stage == .raw)
    #expect(retranscription.origin == .retranscription)
    #expect(retranscription.timedSpans == fixture.transcription.spans)
    #expect(reformat.stage == .formatted)
    #expect(reformat.origin == .reformatting)
    #expect(reformat.sourceResultID == correction.id)
    #expect(reformat.style == .formal)
    #expect(reformat.provider == .appleOnDevice)
    #expect(redelivery.stage == .delivered)
    #expect(redelivery.origin == .redelivery)
    #expect(redelivery.sourceResultID == reformat.id)
    #expect(redelivery.deliveryOutcome == .inserted)
    #expect(fixture.redeliverer.inserted == ["Reformatted text."])
    #expect(stored.results.count == 8)
    #expect(stored.audioArtifactURL?.lastPathComponent == "\(fixture.sessionID).caf")
  }

  @Test
  func failedRedeliveryAppendsFailureEvidenceAndLeavesTextReusable()
    async throws
  {
    let fixture = try HistoryServiceFixture(
      redeliveryFailure: .focusChanged
    )
    defer { fixture.remove() }
    _ = try await fixture.storeSession(withAudio: false)
    let service = fixture.service()
    let source = try #require(
      try await fixture.history.session(id: fixture.sessionID)?
        .results.preferredReusableResult
    )

    await #expect(throws: TranscriptionFailure.focusChanged) {
      try await service.redeliver(
        sessionID: fixture.sessionID,
        sourceResultID: source.id
      )
    }

    let stored = try #require(
      try await fixture.history.session(id: fixture.sessionID)
    )
    let attempt = try #require(stored.results.last)
    #expect(attempt.stage == .delivered)
    #expect(attempt.origin == .redelivery)
    #expect(attempt.text.isEmpty)
    #expect(attempt.deliveryOutcome == .failed)
    #expect(attempt.deliveryFailureReason == .focusChanged)
    #expect(stored.results.preferredReusableResult?.text == "Formatted text.")
  }

  @Test
  func reuseUsesTheExplicitlySelectedEarlierResult() async throws {
    let fixture = try HistoryServiceFixture()
    defer { fixture.remove() }
    _ = try await fixture.storeSession(withAudio: false)
    let service = fixture.service()
    let session = try #require(
      try await fixture.history.session(id: fixture.sessionID)
    )
    let raw = try #require(
      session.results.first(where: { $0.stage == .raw })
    )

    let correction = try await service.correct(
      sessionID: fixture.sessionID,
      sourceResultID: raw.id,
      text: "Correction from Raw."
    )
    let redelivery = try await service.redeliver(
      sessionID: fixture.sessionID,
      sourceResultID: raw.id
    )

    #expect(correction.sourceResultID == raw.id)
    #expect(redelivery.sourceResultID == raw.id)
    #expect(fixture.redeliverer.inserted == ["raw text"])
  }

  @Test
  func retranscriptionRequiresRetainedAudio() async throws {
    let fixture = try HistoryServiceFixture()
    defer { fixture.remove() }
    _ = try await fixture.storeSession(withAudio: false)

    await #expect(throws: VoiceHistoryServiceError.audioUnavailable) {
      try await fixture.service().retranscribe(
        sessionID: fixture.sessionID
      )
    }
  }
}

private final class HistoryServiceFixture: @unchecked Sendable {
  let rootDirectory: URL
  let history: SQLiteVoiceSessionHistory
  let sessionID = UUID()
  let transcription = VoiceHistoryTranscription(
    text: "Retranscribed text.",
    spans: [
      VoiceHistoryTimedSpan(
        startMilliseconds: 0,
        endMilliseconds: 100,
        text: "Retranscribed text."
      )
    ]
  )
  let redeliverer: StubHistoryRedeliverer

  init(redeliveryFailure: TranscriptionFailure? = nil) throws {
    rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_service_\(UUID().uuidString)")
    history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    redeliverer = StubHistoryRedeliverer(failure: redeliveryFailure)
  }

  func service() -> VoiceHistoryService {
    VoiceHistoryService(
      history: history,
      transcriber: StubHistoryTranscriber(output: transcription),
      reformatter: StubHistoryReformatter(),
      redeliverer: redeliverer,
      now: { Date(timeIntervalSince1970: 1_100) }
    )
  }

  func storeSession(withAudio: Bool) async throws
    -> VoiceSessionDocument
  {
    let formattedDocument = try VoiceFormattedDocumentBuilder().build(
      formattedText: "Formatted text.",
      rawText: "raw text",
      style: .natural
    )
    let document = VoiceSessionDocument(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 1_000),
      endedAt: Date(timeIntervalSince1970: 1_001),
      rawText: "raw text",
      editedText: "edited text",
      formattedText: "Formatted text.",
      deliveredText: "Formatted text.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted,
      formattedDocument: formattedDocument
    )
    history.begin(sessionID: sessionID, startedAt: document.startedAt)
    if withAudio {
      history.append(try makeVoiceAudioFixture())
    }
    try await history.complete(document)
    return document
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootDirectory)
  }
}

private struct StubHistoryTranscriber: VoiceHistoryAudioTranscribing {
  let output: VoiceHistoryTranscription

  func transcribe(
    audioURL: URL,
    locale: Locale
  ) async throws -> VoiceHistoryTranscription {
    output
  }
}

private struct StubHistoryReformatter: VoiceHistoryReformatting {
  func reformat(
    text: String,
    sessionID: UUID,
    style: VoiceStyle
  ) async throws -> VoiceHistoryReformat {
    let document = try VoiceFormattedDocumentBuilder().build(
      formattedText: "Reformatted text.",
      rawText: text,
      style: style,
      provider: .appleOnDevice,
      modelIdentifier: "Apple SystemLanguageModel",
      promptRevision: 5
    )
    return VoiceHistoryReformat(
      text: "Reformatted text.",
      document: document
    )
  }
}

private final class StubHistoryRedeliverer:
  VoiceHistoryRedelivering,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let failure: TranscriptionFailure?
  private var storedInserted: [String] = []

  init(failure: TranscriptionFailure?) {
    self.failure = failure
  }

  var inserted: [String] {
    lock.withLock { storedInserted }
  }

  func redeliver(_ text: String) async throws {
    if let failure {
      throw failure
    }
    lock.withLock { storedInserted.append(text) }
  }
}
