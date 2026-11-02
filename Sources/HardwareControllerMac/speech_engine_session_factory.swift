import Foundation
import HardwareControllerCore

/// The selected engine and, for transcribe.cpp, its installed package.
public struct SpeechEngineConfiguration: Equatable, Sendable {
  public let selection: SpeechEngine
  public let package: InstalledASRModelPackage?

  public init(selection: SpeechEngine, package: InstalledASRModelPackage?) {
    self.selection = selection
    self.package = package
  }

  /// The product default: transcribe.cpp, which refuses sessions until set up.
  public static let unconfigured = SpeechEngineConfiguration(
    selection: .transcribeCpp, package: nil)

  /// transcribe.cpp without a package refuses every session; it never runs Apple.
  public var requiresSetup: Bool {
    selection == .transcribeCpp && package == nil
  }
}

/// The selected engine, readable synchronously from any thread.
public final class SpeechEngineSelectionState: @unchecked Sendable {
  private let lock = NSLock()
  private var selection: SpeechEngine

  public init(_ selection: SpeechEngine) {
    self.selection = selection
  }

  public var usesAppleSpeech: Bool {
    lock.withLock { selection == .apple }
  }

  public func update(_ selection: SpeechEngine) {
    lock.withLock { self.selection = selection }
  }
}

/// Creates sessions for the selected engine.
///
/// A missing package is a typed refusal rather than a quiet switch to Apple:
/// the user either installs the package or explicitly selects Apple.
public actor SpeechEngineSessionFactory: ContextualSpeechRecognitionSessionCreating {
  private let apple: any ContextualSpeechRecognitionSessionCreating
  private let engine: TranscribeCppSpeechEngine
  private var configuration: SpeechEngineConfiguration
  private let fallbackHandler: @Sendable (SpeechEngineFallbackReason) -> Void

  /// `onFallback` receives each per-session fallback so the UI can announce it.
  public init(
    configuration: SpeechEngineConfiguration,
    apple: any ContextualSpeechRecognitionSessionCreating = AppleSpeechRecognitionSessionFactory(),
    engine: TranscribeCppSpeechEngine = TranscribeCppSpeechEngine(),
    onFallback: @escaping @Sendable (SpeechEngineFallbackReason) -> Void = { _ in }
  ) {
    self.configuration = configuration
    self.apple = apple
    self.engine = engine
    fallbackHandler = onFallback
  }

  public func configure(_ configuration: SpeechEngineConfiguration) async {
    guard configuration != self.configuration else {
      return
    }
    let previous = self.configuration
    self.configuration = configuration
    if previous.selection == .transcribeCpp, configuration.package != previous.package {
      await engine.shutdown()
    }
  }

  public var engineStatus: TranscribeCppEngineStatus {
    get async { await engine.status }
  }

  public func prepare(locale: Locale) async throws {
    switch configuration.selection {
    case .apple:
      try await apple.prepare(locale: locale)
    case .transcribeCpp:
      guard let package = configuration.package else {
        throw SpeechRecognitionBackendError.engineSetupRequired
      }
      do throws(TranscribeCppEngineFailure) {
        try await engine.prewarm(package)
      } catch .packageInvalid {
        throw SpeechRecognitionBackendError.engineSetupRequired
      } catch {
        // A failed prewarm is retried by the first decode, which falls back.
      }
    }
  }

  public func makeSession(locale: Locale) async throws -> any SpeechRecognitionSession {
    try await makeSession(locale: locale, vocabularyHints: [])
  }

  public func makeSession(
    locale: Locale,
    vocabularyHints: [String]
  ) async throws -> any SpeechRecognitionSession {
    switch configuration.selection {
    case .apple:
      return try await apple.makeSession(locale: locale, vocabularyHints: vocabularyHints)
    case .transcribeCpp:
      guard let package = configuration.package else {
        throw SpeechRecognitionBackendError.engineSetupRequired
      }
      return try TranscribeCppSpeechRecognitionSession(
        engine: engine,
        package: package,
        locale: locale,
        vocabularyHints: vocabularyHints,
        fallback: apple,
        onFallback: fallbackHandler
      )
    }
  }

  public func shutdown() async {
    await apple.shutdown()
    await engine.shutdown()
  }
}
