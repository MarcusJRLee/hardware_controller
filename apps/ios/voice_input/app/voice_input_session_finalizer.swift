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

protocol VoiceInputRecoveryStoring: Sendable {
  func preserveRecovery(
    sessionID: UUID,
    startedAt: Date,
    endedAt: Date,
    reason: VoiceInputCaptureInterruptionReason,
    sourceAudioURL: URL
  ) async throws -> VoiceInputRecoveryDisposition
}

enum VoiceInputRecoveryDisposition: Equatable, Sendable {
  case recovered
  case alreadyFinalized(formattedText: String)
}

extension VoiceInputHistoryRepository: VoiceInputHistoryStoring {}

extension VoiceInputHistoryRepository: VoiceInputRecoveryStoring {
  func preserveRecovery(
    sessionID: UUID,
    startedAt: Date,
    endedAt: Date,
    reason: VoiceInputCaptureInterruptionReason,
    sourceAudioURL: URL
  ) throws -> VoiceInputRecoveryDisposition {
    let session = try saveRecovery(
      sessionID: sessionID,
      startedAt: startedAt,
      endedAt: endedAt,
      reason: reason,
      sourceAudioURL: sourceAudioURL
    )
    if session.recoveryReason == nil {
      return .alreadyFinalized(formattedText: session.formattedText)
    }
    return .recovered
  }
}

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
