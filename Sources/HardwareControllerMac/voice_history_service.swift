import Foundation
import HardwareControllerCore

public enum VoiceHistoryServiceError: Error, Equatable, Sendable {
  case sessionNotFound
  case audioUnavailable
  case noReusableText
  case invalidCorrection
}

public struct VoiceHistoryTranscription: Equatable, Sendable {
  public let text: String
  public let spans: [VoiceHistoryTimedSpan]

  public init(
    text: String,
    spans: [VoiceHistoryTimedSpan]
  ) {
    self.text = text
    self.spans = spans
  }
}

public protocol VoiceHistoryAudioTranscribing: Sendable {
  func transcribe(
    audioURL: URL,
    locale: Locale
  ) async throws -> VoiceHistoryTranscription
}

public struct VoiceHistoryReformat: Equatable, Sendable {
  public let text: String
  public let document: VoiceFormattedDocument

  public init(
    text: String,
    document: VoiceFormattedDocument
  ) {
    self.text = text
    self.document = document
  }
}

public protocol VoiceHistoryReformatting: Sendable {
  func reformat(
    text: String,
    sessionID: UUID,
    style: VoiceStyle
  ) async throws -> VoiceHistoryReformat
}

public protocol VoiceHistoryRedelivering: Sendable {
  func redeliver(_ text: String) async throws
}

public protocol VoiceHistoryServicing: Sendable {
  func correct(
    sessionID: UUID,
    sourceResultID: UUID,
    text: String
  ) async throws
    -> VoiceHistoryResult
  func retranscribe(sessionID: UUID) async throws
    -> VoiceHistoryResult
  func reformat(
    sessionID: UUID,
    sourceResultID: UUID,
    style: VoiceStyle
  ) async throws
    -> VoiceHistoryResult
  func redeliver(
    sessionID: UUID,
    sourceResultID: UUID
  ) async throws
    -> VoiceHistoryResult
}

/// Coordinates explicit History reuse while preserving every prior result.
public actor VoiceHistoryService: VoiceHistoryServicing {
  private let history: any VoiceSessionHistoryAccessing
  private let transcriber: any VoiceHistoryAudioTranscribing
  private let reformatter: any VoiceHistoryReformatting
  private let redeliverer: any VoiceHistoryRedelivering
  private let locale: Locale
  private let now: @Sendable () -> Date

  public init(
    history: any VoiceSessionHistoryAccessing,
    transcriber: any VoiceHistoryAudioTranscribing,
    reformatter: any VoiceHistoryReformatting,
    redeliverer: any VoiceHistoryRedelivering,
    locale: Locale = .current,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.history = history
    self.transcriber = transcriber
    self.reformatter = reformatter
    self.redeliverer = redeliverer
    self.locale = locale
    self.now = now
  }

  @discardableResult
  public func correct(
    sessionID: UUID,
    sourceResultID: UUID,
    text: String
  ) async throws -> VoiceHistoryResult {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw VoiceHistoryServiceError.invalidCorrection
    }
    let session = try await requiredSession(id: sessionID)
    let source = try requiredResult(
      id: sourceResultID,
      in: session,
      requiresText: false
    )
    let result = VoiceHistoryResult(
      sessionID: sessionID,
      createdAt: now(),
      stage: .corrected,
      origin: .correction,
      text: text,
      sourceResultID: source.id
    )
    try await history.appendResult(result)
    return result
  }

  @discardableResult
  public func retranscribe(
    sessionID: UUID
  ) async throws -> VoiceHistoryResult {
    let session = try await requiredSession(id: sessionID)
    guard let audioURL = session.audioArtifactURL else {
      throw VoiceHistoryServiceError.audioUnavailable
    }
    let source =
      try
      (session.results.last(where: { $0.stage == .raw })
      ?? requiredReusableResult(in: session))
    let output = try await transcriber.transcribe(
      audioURL: audioURL,
      locale: locale
    )
    guard
      !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw VoiceHistoryServiceError.noReusableText
    }
    let result = VoiceHistoryResult(
      sessionID: sessionID,
      createdAt: now(),
      stage: .raw,
      origin: .retranscription,
      text: output.text,
      sourceResultID: source.id,
      timedSpans: output.spans
    )
    try await history.appendResult(result)
    return result
  }

  @discardableResult
  public func reformat(
    sessionID: UUID,
    sourceResultID: UUID,
    style: VoiceStyle
  ) async throws -> VoiceHistoryResult {
    let session = try await requiredSession(id: sessionID)
    let source = try requiredResult(
      id: sourceResultID,
      in: session,
      requiresText: true
    )
    let output = try await reformatter.reformat(
      text: source.text,
      sessionID: sessionID,
      style: style
    )
    let evidence = output.document.evidence.first
    let result = VoiceHistoryResult(
      sessionID: sessionID,
      createdAt: now(),
      stage: .formatted,
      origin: .reformatting,
      text: output.text,
      sourceResultID: source.id,
      style: output.document.style,
      provider: evidence?.provider,
      modelIdentifier: evidence?.modelIdentifier,
      promptRevision: evidence?.promptRevision,
      formattedDocument: output.document
    )
    try await history.appendResult(result)
    return result
  }

  @discardableResult
  public func redeliver(
    sessionID: UUID,
    sourceResultID: UUID
  ) async throws -> VoiceHistoryResult {
    let session = try await requiredSession(id: sessionID)
    let source = try requiredResult(
      id: sourceResultID,
      in: session,
      requiresText: true
    )
    do {
      try await redeliverer.redeliver(source.text)
      let result = VoiceHistoryResult(
        sessionID: sessionID,
        createdAt: now(),
        stage: .delivered,
        origin: .redelivery,
        text: source.text,
        sourceResultID: source.id,
        deliveryOutcome: .inserted
      )
      try await history.appendResult(result)
      return result
    } catch {
      let transcriptionFailure =
        error as? TranscriptionFailure ?? .insertionFailed
      let result = VoiceHistoryResult(
        sessionID: sessionID,
        createdAt: now(),
        stage: .delivered,
        origin: .redelivery,
        text: "",
        sourceResultID: source.id,
        deliveryOutcome: .failed,
        deliveryFailure: deliveryMessage(transcriptionFailure),
        deliveryFailureReason:
          VoiceSessionDeliveryFailureReason(transcriptionFailure)
          ?? .insertionRejected
      )
      try await history.appendResult(result)
      throw error
    }
  }

  private func requiredSession(
    id: UUID
  ) async throws -> VoiceSessionHistoryItem {
    guard let session = try await history.session(id: id) else {
      throw VoiceHistoryServiceError.sessionNotFound
    }
    return session
  }

  private func requiredReusableResult(
    in session: VoiceSessionHistoryItem
  ) throws -> VoiceHistoryResult {
    guard let result = session.results.preferredReusableResult else {
      throw VoiceHistoryServiceError.noReusableText
    }
    return result
  }

  private func requiredResult(
    id: UUID,
    in session: VoiceSessionHistoryItem,
    requiresText: Bool
  ) throws -> VoiceHistoryResult {
    guard
      let result = session.results.first(where: {
        $0.id == id && (!requiresText || !$0.text.isEmpty)
      })
    else {
      throw VoiceHistoryServiceError.noReusableText
    }
    return result
  }

  private func deliveryMessage(
    _ failure: TranscriptionFailure
  ) -> String {
    switch failure {
    case .focusChanged:
      "The focused field changed before re-delivery."
    case .processChanged:
      "The target application changed before re-delivery."
    case .secureTextField:
      "Voice History cannot insert into a secure field."
    case .caretChanged:
      "The text cursor changed before re-delivery."
    case .noFocusedTextField:
      "No editable text field was focused for re-delivery."
    case .insertionFailed:
      "The target rejected the re-delivery."
    case .microphonePermissionDenied,
      .speechRecognitionPermissionDenied,
      .localeUnsupported,
      .modelUnavailable,
      .audioUnavailable,
      .recognitionFailed:
      "Voice History could not re-deliver the text."
    }
  }
}
