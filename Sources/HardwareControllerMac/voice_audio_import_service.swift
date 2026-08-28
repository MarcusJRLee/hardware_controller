import Foundation
import HardwareControllerCore

public struct VoiceAudioImportLimits: Equatable, Sendable {
  public static let macOSDefault = VoiceAudioImportLimits(
    maximumSourceBytes: 2 * 1_024 * 1_024 * 1_024,
    maximumDurationMilliseconds: 12 * 60 * 60 * 1_000,
    maximumRetainedAudioBytes: 2 * 1_024 * 1_024 * 1_024
  )

  public let maximumSourceBytes: Int64
  public let maximumDurationMilliseconds: Int64
  public let maximumRetainedAudioBytes: Int64

  public init(
    maximumSourceBytes: Int64,
    maximumDurationMilliseconds: Int64,
    maximumRetainedAudioBytes: Int64? = nil
  ) {
    self.maximumSourceBytes = maximumSourceBytes
    self.maximumDurationMilliseconds = maximumDurationMilliseconds
    self.maximumRetainedAudioBytes =
      maximumRetainedAudioBytes ?? maximumSourceBytes
  }

  func validated() throws -> Self {
    guard
      maximumSourceBytes > 0,
      maximumDurationMilliseconds > 0,
      maximumRetainedAudioBytes > 0
    else {
      throw VoiceAudioImportError.invalidLimits
    }
    return self
  }
}

public enum VoiceAudioImportError:
  Error,
  Equatable,
  LocalizedError,
  Sendable
{
  case invalidLimits
  case sourceUnavailable
  case sourceTooLarge
  case durationTooLong
  case retainedAudioTooLarge
  case emptyAudio
  case unsupportedAudio
  case couldNotStore

  public var errorDescription: String? {
    switch self {
    case .invalidLimits:
      "Audio import limits are invalid."
    case .sourceUnavailable:
      "The selected audio file is unavailable."
    case .sourceTooLarge:
      "The selected audio file exceeds the configured import-size limit."
    case .durationTooLong:
      "The selected recording exceeds the configured duration limit."
    case .retainedAudioTooLarge:
      "The decoded recording exceeds the configured local-storage limit."
    case .emptyAudio:
      "The selected file contains no audio."
    case .unsupportedAudio:
      "The selected file is not a supported audio recording."
    case .couldNotStore:
      "Voice History could not store the imported recording."
    }
  }
}

public enum VoiceAudioImportProcessingOutcome:
  Equatable,
  Sendable
{
  case formatted
  case transcriptOnly
  case audioOnly
}

public struct VoiceAudioImportResult: Equatable, Sendable {
  public let sessionID: UUID
  public let processingOutcome: VoiceAudioImportProcessingOutcome

  public init(
    sessionID: UUID,
    processingOutcome: VoiceAudioImportProcessingOutcome
  ) {
    self.sessionID = sessionID
    self.processingOutcome = processingOutcome
  }
}

public protocol VoiceAudioImporting: Sendable {
  func importAudio(
    from sourceURL: URL,
    style: VoiceStyle
  ) async throws -> VoiceAudioImportResult
}

/// Converts one user-selected recording into immutable local History evidence.
public actor VoiceAudioImportService: VoiceAudioImporting {
  private let history: any VoiceSessionHistoryImporting
  private let transcriber: any VoiceHistoryAudioTranscribing
  private let reformatter: any VoiceHistoryReformatting
  private let limits: VoiceAudioImportLimits
  private let locale: Locale
  private let now: @Sendable () -> Date

  public init(
    history: any VoiceSessionHistoryImporting,
    transcriber: any VoiceHistoryAudioTranscribing,
    reformatter: any VoiceHistoryReformatting,
    limits: VoiceAudioImportLimits = .macOSDefault,
    locale: Locale = .current,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.history = history
    self.transcriber = transcriber
    self.reformatter = reformatter
    self.limits = limits
    self.locale = locale
    self.now = now
  }

  public func importAudio(
    from sourceURL: URL,
    style: VoiceStyle
  ) async throws -> VoiceAudioImportResult {
    let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityScope {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }
    _ = try VoiceAudioImportInspector.inspect(
      sourceURL: sourceURL,
      limits: limits
    )

    let sessionID = UUID()
    let startedAt = now()
    let transcription: VoiceHistoryTranscription?
    do {
      transcription = try await transcriber.transcribe(
        audioURL: sourceURL,
        locale: locale
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      transcription = nil
    }
    let rawText = transcription?.text ?? ""
    let hasRawText = !rawText.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).isEmpty
    let processing: VoiceAudioImportProcessingOutcome
    let formattedText: String
    let formattedDocument: VoiceFormattedDocument?
    if !hasRawText {
      processing = .audioOnly
      formattedText = ""
      formattedDocument = nil
    } else {
      do {
        let formatted = try await reformatter.reformat(
          text: rawText,
          sessionID: sessionID,
          style: style
        )
        processing = .formatted
        formattedText = formatted.text
        formattedDocument = formatted.document
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        processing = .transcriptOnly
        formattedText = rawText
        formattedDocument = nil
      }
    }
    try Task.checkCancellation()
    let document = VoiceSessionDocument(
      id: sessionID,
      startedAt: startedAt,
      endedAt: now(),
      rawText: rawText,
      editedText: rawText,
      formattedText: formattedText,
      deliveredText: "",
      targetApplicationName: nil,
      deliveryOutcome: .notAttempted,
      formattedDocument: formattedDocument,
      inputKind: .importedAudio
    )
    try await history.importAudioSession(
      document,
      from: sourceURL,
      limits: limits
    )
    return VoiceAudioImportResult(
      sessionID: sessionID,
      processingOutcome: processing
    )
  }
}
