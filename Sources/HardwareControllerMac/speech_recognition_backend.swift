@preconcurrency import AVFoundation
import Foundation
import HardwareControllerCore

public enum SpeechRecognitionBackendKind:
  Equatable,
  Sendable
{
  case speechAnalyzer
  case legacyOnDevice
}

public enum SpeechRecognitionBackendError:
  Equatable,
  Error,
  Sendable
{
  case unavailable
  case localeUnsupported
  case modelUnavailable
  case conversionFailed(String)
  case recognitionFailed(String)
  case recognitionInterrupted
}

public protocol SpeechRecognitionSession: Sendable {
  var updates: AsyncThrowingStream<TranscriptRevision, any Error>
  { get }

  func append(_ audio: CapturedAudioBuffer) async throws
  func finish() async throws
  func cancel() async
}

public protocol SpeechRecognitionSessionCreating: Sendable {
  func prepare(
    locale: Locale
  ) async throws

  func makeSession(
    locale: Locale
  ) async throws -> any SpeechRecognitionSession

  func shutdown() async
}

/// Adds optional vocabulary without changing the shared session contract.
public protocol ContextualSpeechRecognitionSessionCreating:
  SpeechRecognitionSessionCreating
{
  func makeSession(
    locale: Locale,
    vocabularyHints: [String]
  ) async throws -> any SpeechRecognitionSession
}

extension SpeechRecognitionSessionCreating {
  public func prepare(locale: Locale) async throws {}

  public func shutdown() async {}
}

public actor AppleSpeechRecognitionSessionFactory:
  ContextualSpeechRecognitionSessionCreating
{
  private var modernConfiguration: SpeechAnalyzerRecognitionConfiguration?
  private var modernConfigurationLocaleIdentifier: String?
  private var modernPreparation: Task<SpeechAnalyzerRecognitionConfiguration, any Error>?
  private var modernPreparationID: UUID?
  private var isShutDown = false

  public init() {}

  public func prepare(
    locale: Locale
  ) async throws {
    guard !isShutDown else {
      throw SpeechRecognitionBackendError.unavailable
    }
    if #available(macOS 26, *) {
      _ = try await preparedModernConfiguration(
        for: locale
      )
    }
  }

  public func makeSession(
    locale: Locale
  ) async throws -> any SpeechRecognitionSession {
    try await makeSession(locale: locale, vocabularyHints: [])
  }

  public func makeSession(
    locale: Locale,
    vocabularyHints: [String]
  ) async throws -> any SpeechRecognitionSession {
    guard !isShutDown else {
      throw SpeechRecognitionBackendError.unavailable
    }
    if #available(macOS 26, *) {
      let configuration =
        try await preparedModernConfiguration(
          for: locale
        )
      return try await SpeechAnalyzerRecognitionSession.make(
        configuration: configuration,
        vocabularyHints: vocabularyHints
      )
    }
    return try await LegacyOnDeviceSpeechRecognitionSession.make(
      locale: locale,
      vocabularyHints: vocabularyHints
    )
  }

  public func shutdown() async {
    guard !isShutDown else {
      return
    }
    isShutDown = true
    modernPreparation?.cancel()
    modernPreparation = nil
    modernPreparationID = nil
    if #available(macOS 26, *),
      let modernConfiguration
    {
      await SpeechAnalyzerRecognitionSession.release(
        configuration: modernConfiguration
      )
    }
    modernConfiguration = nil
    modernConfigurationLocaleIdentifier = nil
  }

  static func backendKind(
    for version: OperatingSystemVersion
  ) -> SpeechRecognitionBackendKind {
    version.majorVersion >= 26
      ? .speechAnalyzer
      : .legacyOnDevice
  }

  @available(macOS 26, *)
  private func preparedModernConfiguration(
    for locale: Locale
  ) async throws -> SpeechAnalyzerRecognitionConfiguration {
    let localeIdentifier = locale.identifier
    if modernConfigurationLocaleIdentifier == localeIdentifier,
      let modernConfiguration
    {
      return modernConfiguration
    }

    let task:
      Task<
        SpeechAnalyzerRecognitionConfiguration,
        any Error
      >
    let preparationID: UUID
    if modernConfigurationLocaleIdentifier == localeIdentifier,
      let modernPreparation,
      let existingID = modernPreparationID
    {
      task = modernPreparation
      preparationID = existingID
    } else {
      if let modernConfiguration {
        await SpeechAnalyzerRecognitionSession.release(
          configuration: modernConfiguration
        )
        self.modernConfiguration = nil
      }
      modernPreparation?.cancel()

      let createdID = UUID()
      task = Task {
        try await SpeechAnalyzerRecognitionSession.prepare(
          locale: locale
        )
      }
      modernPreparation = task
      modernPreparationID = createdID
      modernConfigurationLocaleIdentifier =
        localeIdentifier
      preparationID = createdID
    }

    do {
      let prepared = try await task.value
      guard !isShutDown else {
        await SpeechAnalyzerRecognitionSession.release(
          configuration: prepared
        )
        throw CancellationError()
      }
      if let modernConfiguration {
        return modernConfiguration
      }
      guard modernPreparationID == preparationID else {
        await SpeechAnalyzerRecognitionSession.release(
          configuration: prepared
        )
        throw CancellationError()
      }
      modernConfiguration = prepared
      modernPreparation = nil
      modernPreparationID = nil
      return prepared
    } catch {
      if modernPreparationID == preparationID {
        modernPreparation = nil
        modernPreparationID = nil
        modernConfigurationLocaleIdentifier = nil
      }
      throw error
    }
  }
}
