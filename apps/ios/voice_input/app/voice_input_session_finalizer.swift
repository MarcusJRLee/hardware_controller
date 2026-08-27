import Foundation
import HardwareControllerVoiceCore

protocol VoiceInputHistoryStoring: Sendable {
  func save(
    sessionID: UUID,
    startedAt: Date,
    endedAt: Date,
    transcript: VoiceInputProcessedTranscript,
    sourceAudioURL: URL
  ) async throws -> VoiceInputHistorySession
}

extension VoiceInputHistoryRepository: VoiceInputHistoryStoring {}

struct VoiceInputSessionFinalizer: Sendable {
  private let pipeline: VoiceInputDocumentPipeline
  private let history: any VoiceInputHistoryStoring

  init(
    pipeline: VoiceInputDocumentPipeline = VoiceInputDocumentPipeline(),
    history: any VoiceInputHistoryStoring
  ) {
    self.pipeline = pipeline
    self.history = history
  }

  func finalize(
    sessionID: UUID,
    startedAt: Date,
    endedAt: Date,
    rawTranscript: VoiceInputRawTranscript,
    sourceAudioURL: URL,
    style: VoiceStyle
  ) async throws -> VoiceInputProcessedTranscript {
    let processed = try pipeline.process(rawTranscript, style: style)
    _ = try await history.save(
      sessionID: sessionID,
      startedAt: startedAt,
      endedAt: endedAt,
      transcript: processed,
      sourceAudioURL: sourceAudioURL
    )
    return processed
  }
}
