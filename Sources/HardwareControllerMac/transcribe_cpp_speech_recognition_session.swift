import Foundation
import HardwareControllerCore

/// A session that can say which engine produced its text.
public protocol SpeechEngineReporting: Sendable {
  var engineUsage: SpeechEngineUsage { get async }
}

/// Buffers a recording and transcribes it with transcribe.cpp on finish.
///
/// When the service fails, the same buffered audio goes to Apple's recognizer,
/// so no recording is lost; `onFallback` announces it so it is never silent.
public actor TranscribeCppSpeechRecognitionSession:
  SpeechRecognitionSession,
  SpeechEngineReporting
{
  public nonisolated let updates: AsyncThrowingStream<TranscriptRevision, any Error>

  private enum Phase {
    case accepting
    case finishing
    case ended
  }

  private let continuation: AsyncThrowingStream<TranscriptRevision, any Error>.Continuation
  private let engine: TranscribeCppSpeechEngine
  private let package: InstalledASRModelPackage
  private let locale: Locale
  private let vocabularyHints: [String]
  private let fallback: any ContextualSpeechRecognitionSessionCreating
  private let onFallback: @Sendable (SpeechEngineFallbackReason) -> Void
  private var accumulator: ASRSampleAccumulator
  private var phase = Phase.accepting
  private var fallbackSession: (any SpeechRecognitionSession)?
  private var usage: SpeechEngineUsage

  public init(
    engine: TranscribeCppSpeechEngine,
    package: InstalledASRModelPackage,
    locale: Locale,
    vocabularyHints: [String],
    fallback: any ContextualSpeechRecognitionSessionCreating,
    onFallback: @escaping @Sendable (SpeechEngineFallbackReason) -> Void
  ) throws(SpeechRecognitionBackendError) {
    (updates, continuation) = AsyncThrowingStream.makeStream()
    self.engine = engine
    self.package = package
    self.locale = locale
    self.vocabularyHints = vocabularyHints
    self.fallback = fallback
    self.onFallback = onFallback
    accumulator = try ASRSampleAccumulator()
    usage = SpeechEngineUsage(
      engine: .transcribeCpp,
      modelPackageID: package.packageID,
      modelPackageVersion: package.version,
      modelDisplayName: package.displayName
    )
  }

  public var engineUsage: SpeechEngineUsage {
    usage
  }

  public func append(_ audio: CapturedAudioBuffer) throws {
    guard case .accepting = phase else {
      throw SpeechRecognitionBackendError.unavailable
    }
    try accumulator.append(audio.makePCMBuffer())
  }

  public func finish() async throws {
    guard case .accepting = phase else {
      return
    }
    phase = .finishing
    try accumulator.flush()
    guard !accumulator.samples.isEmpty else {
      end()
      return
    }
    do throws(TranscribeCppEngineFailure) {
      let transcript = try await engine.transcribe(
        accumulator.samples,
        package: package,
        language: Self.runtimeLanguage(for: locale),
        vocabulary: vocabularyHints
      )
      guard case .finishing = phase else {
        return
      }
      continuation.yield(.committed(transcript.text))
      end()
    } catch .noSpeechDetected {
      end()
    } catch .packageInvalid {
      end(throwing: SpeechRecognitionBackendError.engineSetupRequired)
      throw SpeechRecognitionBackendError.engineSetupRequired
    } catch .serviceFailed {
      try await transcribeWithFallback(reason: .serviceFailed)
    } catch .disabledUntilRelaunch {
      try await transcribeWithFallback(reason: .disabledUntilRelaunch)
    }
  }

  public func cancel() async {
    guard !isEnded else {
      return
    }
    end()
    await fallbackSession?.cancel()
  }

  private var isEnded: Bool {
    if case .ended = phase {
      return true
    }
    return false
  }

  private func transcribeWithFallback(reason: SpeechEngineFallbackReason) async throws {
    guard case .finishing = phase else {
      return
    }
    onFallback(reason)
    usage = SpeechEngineUsage(engine: .apple, fallbackReason: reason)
    do {
      let session = try await fallback.makeSession(
        locale: locale,
        vocabularyHints: vocabularyHints
      )
      fallbackSession = session
      let continuation = continuation
      let forward = Task {
        for try await revision in session.updates {
          continuation.yield(revision)
        }
      }
      for buffer in try accumulator.pcmBuffers() {
        try await session.append(CapturedAudioBuffer(copying: buffer))
      }
      try await session.finish()
      try await forward.value
      end()
    } catch {
      end(throwing: error)
      throw error
    }
  }

  private func end(throwing error: (any Error)? = nil) {
    phase = .ended
    continuation.finish(throwing: error)
  }

  /// transcribe.cpp takes a primary language subtag, or `auto`.
  static func runtimeLanguage(for locale: Locale) -> String {
    guard
      let code = locale.language.languageCode?.identifier,
      (2...3).contains(code.count),
      code.allSatisfy(\.isLetter)
    else {
      return "auto"
    }
    return code.lowercased()
  }
}
