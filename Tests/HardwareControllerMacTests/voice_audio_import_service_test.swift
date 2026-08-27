import AVFoundation
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct VoiceAudioImportServiceTest {
  @Test
  func importedFileBecomesFormattedSearchableOwnedHistory() async throws {
    let fixture = try VoiceAudioImportFixture()
    defer { fixture.remove() }
    let sourceData = try Data(contentsOf: fixture.sourceURL)

    let result = try await fixture.service().importAudio(
      from: fixture.sourceURL,
      style: .technical
    )

    let stored = try #require(
      try await fixture.history.session(id: result.sessionID)
    )
    #expect(result.processingOutcome == .formatted)
    #expect(stored.document.inputKind == .importedAudio)
    #expect(stored.document.deliveryOutcome == .notAttempted)
    #expect(stored.document.rawText == "Imported raw text.")
    #expect(stored.document.formattedText == "- Imported formatted text.")
    #expect(stored.document.deliveredText.isEmpty)
    #expect(stored.audioDurationMilliseconds == 100)
    #expect(stored.audioArtifactURL?.lastPathComponent == "\(result.sessionID).caf")
    #expect(stored.results.first?.origin == .audioImport)
    #expect(stored.results.first?.timedSpans.first?.text == "Imported raw text.")
    #expect(try Data(contentsOf: fixture.sourceURL) == sourceData)
    #expect(stored.audioArtifactURL != fixture.sourceURL)
  }

  @Test
  func transcriptionFailurePreservesAudioOnlyHistory() async throws {
    let fixture = try VoiceAudioImportFixture()
    defer { fixture.remove() }

    let result = try await fixture.service(
      transcriptionFailure: ImportFixtureError.unavailable
    ).importAudio(from: fixture.sourceURL, style: .natural)

    let stored = try #require(
      try await fixture.history.session(id: result.sessionID)
    )
    #expect(result.processingOutcome == .audioOnly)
    #expect(stored.document.inputKind == .importedAudio)
    #expect(stored.results.allSatisfy { $0.text.isEmpty })
    #expect(stored.audioArtifactURL != nil)
  }

  @Test
  func formattingFailureFallsBackToTheRawTranscript() async throws {
    let fixture = try VoiceAudioImportFixture()
    defer { fixture.remove() }

    let result = try await fixture.service(
      formattingFailure: ImportFixtureError.unavailable
    ).importAudio(from: fixture.sourceURL, style: .formal)

    let stored = try #require(
      try await fixture.history.session(id: result.sessionID)
    )
    #expect(result.processingOutcome == .transcriptOnly)
    #expect(stored.document.rawText == "Imported raw text.")
    #expect(stored.document.formattedText == "Imported raw text.")
    #expect(stored.document.formattedDocument == nil)
    #expect(stored.audioArtifactURL != nil)
  }

  @Test
  func rawImportEvidencePreservesRecognizerWhitespace() async throws {
    let fixture = try VoiceAudioImportFixture()
    defer { fixture.remove() }

    let result = try await fixture.service(
      transcriptionText: "  Imported raw text.\n"
    ).importAudio(from: fixture.sourceURL, style: .verbatim)

    let stored = try #require(
      try await fixture.history.session(id: result.sessionID)
    )
    #expect(stored.document.rawText == "  Imported raw text.\n")
  }

  @Test
  func configuredSourceLimitRejectsBeforeHistoryMutation() async throws {
    let fixture = try VoiceAudioImportFixture()
    defer { fixture.remove() }
    let size = Int64(try Data(contentsOf: fixture.sourceURL).count)
    let service = fixture.service(
      limits: VoiceAudioImportLimits(
        maximumSourceBytes: size - 1,
        maximumDurationMilliseconds: 10_000
      )
    )

    await #expect(throws: VoiceAudioImportError.sourceTooLarge) {
      try await service.importAudio(
        from: fixture.sourceURL,
        style: .natural
      )
    }
    #expect(try await fixture.history.recentSessions(limit: 10).isEmpty)
  }

  @Test
  func configuredDurationLimitRejectsBeforeHistoryMutation() async throws {
    let fixture = try VoiceAudioImportFixture()
    defer { fixture.remove() }
    let service = fixture.service(
      limits: VoiceAudioImportLimits(
        maximumSourceBytes: 1_024 * 1_024,
        maximumDurationMilliseconds: 99
      )
    )

    await #expect(throws: VoiceAudioImportError.durationTooLong) {
      try await service.importAudio(
        from: fixture.sourceURL,
        style: .natural
      )
    }
    #expect(try await fixture.history.recentSessions(limit: 10).isEmpty)
  }

  @Test
  func configuredRetainedSizeRejectsDecodedAudioBeforeMutation() async throws {
    let fixture = try VoiceAudioImportFixture()
    defer { fixture.remove() }
    let service = fixture.service(
      limits: VoiceAudioImportLimits(
        maximumSourceBytes: 1_024 * 1_024,
        maximumDurationMilliseconds: 10_000,
        maximumRetainedAudioBytes: 100
      )
    )

    await #expect(throws: VoiceAudioImportError.retainedAudioTooLarge) {
      try await service.importAudio(
        from: fixture.sourceURL,
        style: .natural
      )
    }
    #expect(try await fixture.history.recentSessions(limit: 10).isEmpty)
  }

  @Test
  func cancellationDoesNotCreateHistory() async throws {
    let fixture = try VoiceAudioImportFixture()
    defer { fixture.remove() }

    await #expect(throws: CancellationError.self) {
      try await fixture.service(
        transcriptionFailure: CancellationError()
      ).importAudio(from: fixture.sourceURL, style: .natural)
    }

    #expect(try await fixture.history.recentSessions(limit: 10).isEmpty)
  }
}

private enum ImportFixtureError: Error {
  case unavailable
}

private final class VoiceAudioImportFixture: @unchecked Sendable {
  let root: URL
  let sourceURL: URL
  let history: SQLiteVoiceSessionHistory

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "voice_audio_import_\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    sourceURL = root.appending(path: "source.wav")
    let captured = try makeVoiceAudioFixture()
    let buffer = try captured.makePCMBuffer()
    let file = try AVAudioFile(
      forWriting: sourceURL,
      settings: buffer.format.settings
    )
    try file.write(from: buffer)
    history = try SQLiteVoiceSessionHistory(
      rootDirectory: root.appending(path: "history")
    )
  }

  func service(
    transcriptionFailure: (any Error)? = nil,
    transcriptionText: String = "Imported raw text.",
    formattingFailure: (any Error)? = nil,
    limits: VoiceAudioImportLimits = .macOSDefault
  ) -> VoiceAudioImportService {
    VoiceAudioImportService(
      history: history,
      transcriber: ImportFixtureTranscriber(
        text: transcriptionText,
        failure: transcriptionFailure
      ),
      reformatter: ImportFixtureReformatter(failure: formattingFailure),
      limits: limits,
      now: { Date(timeIntervalSince1970: 1_000) }
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct ImportFixtureTranscriber: VoiceHistoryAudioTranscribing {
  let text: String
  let failure: (any Error)?

  func transcribe(
    audioURL: URL,
    locale: Locale
  ) async throws -> VoiceHistoryTranscription {
    if let failure {
      throw failure
    }
    return VoiceHistoryTranscription(
      text: text,
      spans: []
    )
  }
}

private struct ImportFixtureReformatter: VoiceHistoryReformatting {
  let failure: (any Error)?

  func reformat(
    text: String,
    sessionID: UUID,
    style: VoiceStyle
  ) async throws -> VoiceHistoryReformat {
    if let failure {
      throw failure
    }
    let formatted = "- Imported formatted text."
    return VoiceHistoryReformat(
      text: formatted,
      document: try VoiceFormattedDocumentBuilder().build(
        formattedText: formatted,
        rawText: text,
        style: style
      )
    )
  }
}
