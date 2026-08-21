@preconcurrency import AVFoundation
import Foundation
import HardwareControllerCore
import Speech

/// Carries immutable AVFoundation format metadata between factory calls.
struct SpeechAnalyzerRecognitionConfiguration:
  @unchecked Sendable
{
  let locale: Locale
  let audioFormat: AVAudioFormat
}

/// Models cancellation and result termination for a modern speech session.
struct SpeechAnalyzerRecognitionLifecycle: Sendable {
  private enum Phase: Sendable {
    case acceptingInput
    case finalizing
    case stopped
  }

  private var phase = Phase.acceptingInput

  var acceptsInput: Bool {
    phase == .acceptingInput
  }

  /// Begins finalization only while input is still accepted.
  mutating func beginFinalization() -> Bool {
    guard phase == .acceptingInput else {
      return false
    }
    phase = .finalizing
    return true
  }

  /// Stops once and reports whether cancellation work remains.
  mutating func stop() -> Bool {
    guard phase != .stopped else {
      return false
    }
    phase = .stopped
    return true
  }

  /// Reports whether normal result exhaustion occurred too early.
  var resultEndedUnexpectedly: Bool {
    phase == .acceptingInput
  }

  /// Reports whether a thrown cancellation lacked an explicit owner.
  func cancellationWasUnexpected(
    taskIsCancelled: Bool
  ) -> Bool {
    phase != .stopped && !taskIsCancelled
  }
}

@available(macOS 26, *)
actor SpeechAnalyzerRecognitionSession:
  SpeechRecognitionSession
{
  nonisolated let updates: AsyncThrowingStream<TranscriptRevision, any Error>

  private let transcriber: DictationTranscriber
  private let analyzer: SpeechAnalyzer
  private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
  private let updateContinuation:
    AsyncThrowingStream<
      TranscriptRevision,
      any Error
    >.Continuation
  private let inputStream: AsyncStream<AnalyzerInput>
  private let converter: SpeechAudioBufferConverter
  private var resultTask: Task<Void, Never>?
  private var committedText = ""
  private var lifecycle = SpeechAnalyzerRecognitionLifecycle()

  /// Resolves locale, local model, and required audio format.
  static func prepare(
    locale requestedLocale: Locale
  ) async throws -> SpeechAnalyzerRecognitionConfiguration {
    guard
      let locale =
        await DictationTranscriber
        .supportedLocale(equivalentTo: requestedLocale)
    else {
      throw SpeechRecognitionBackendError.localeUnsupported
    }

    let transcriber = makeTranscriber(
      locale: locale,
    )
    try await ensureModel(
      for: transcriber,
      locale: locale
    )
    guard
      let audioFormat =
        await SpeechAnalyzer.bestAvailableAudioFormat(
          compatibleWith: [transcriber]
        )
    else {
      _ = await AssetInventory.release(
        reservedLocale: locale
      )
      throw SpeechRecognitionBackendError.unavailable
    }
    return SpeechAnalyzerRecognitionConfiguration(
      locale: locale,
      audioFormat: audioFormat
    )
  }

  /// Creates and starts one prepared modern recognition session.
  static func make(
    configuration: SpeechAnalyzerRecognitionConfiguration,
    vocabularyHints: [String] = []
  ) async throws -> SpeechAnalyzerRecognitionSession {
    let transcriber = makeTranscriber(
      locale: configuration.locale
    )
    let (inputStream, inputContinuation) =
      AsyncStream<AnalyzerInput>.makeStream(
        bufferingPolicy: .bufferingNewest(32)
      )
    let (updates, updateContinuation) =
      AsyncThrowingStream<
        TranscriptRevision,
        any Error
      >.makeStream(
        bufferingPolicy: .bufferingNewest(32)
      )
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    if !vocabularyHints.isEmpty {
      let context = AnalysisContext()
      context.contextualStrings[.general] = vocabularyHints
      try await analyzer.setContext(context)
    }
    let session = SpeechAnalyzerRecognitionSession(
      transcriber: transcriber,
      analyzer: analyzer,
      inputStream: inputStream,
      inputContinuation: inputContinuation,
      updates: updates,
      updateContinuation: updateContinuation,
      converter: SpeechAudioBufferConverter(
        targetFormat: configuration.audioFormat
      )
    )
    try await session.start()
    return session
  }

  /// Stores actor-confined analyzer resources and bounded streams.
  private init(
    transcriber: DictationTranscriber,
    analyzer: SpeechAnalyzer,
    inputStream: AsyncStream<AnalyzerInput>,
    inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
    updates: AsyncThrowingStream<TranscriptRevision, any Error>,
    updateContinuation:
      AsyncThrowingStream<
        TranscriptRevision,
        any Error
      >.Continuation,
    converter: SpeechAudioBufferConverter
  ) {
    self.transcriber = transcriber
    self.analyzer = analyzer
    self.inputStream = inputStream
    self.inputContinuation = inputContinuation
    self.updates = updates
    self.updateContinuation = updateContinuation
    self.converter = converter
  }

  /// Appends audio only while the session still accepts input.
  func append(_ audio: CapturedAudioBuffer) async throws {
    guard lifecycle.acceptsInput else {
      throw SpeechRecognitionBackendError.unavailable
    }
    let buffer = try converter.convert(audio)
    switch inputContinuation.yield(
      AnalyzerInput(buffer: buffer)
    ) {
    case .enqueued:
      break
    case .dropped:
      throw
        SpeechRecognitionBackendError
        .recognitionFailed("Speech input could not keep up.")
    case .terminated:
      throw SpeechRecognitionBackendError.unavailable
    @unknown default:
      throw SpeechRecognitionBackendError.unavailable
    }
  }

  /// Finalizes accepted input while permitting concurrent forced cancellation.
  func finish() async throws {
    guard lifecycle.beginFinalization() else {
      return
    }
    defer {
      _ = lifecycle.stop()
    }
    inputContinuation.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    await resultTask?.value
  }

  /// Interrupts running or in-progress finalization exactly once.
  func cancel() async {
    guard lifecycle.stop() else {
      return
    }
    inputContinuation.finish()
    await analyzer.cancelAndFinishNow()
    resultTask?.cancel()
    updateContinuation.finish()
  }

  /// Starts result consumption before analyzer input begins.
  private func start() async throws {
    resultTask = Task {
      do {
        for try await result in transcriber.results {
          let text = String(result.text.characters)
          if result.isFinal {
            TranscriptAccumulator.append(
              text,
              to: &committedText
            )
            updateContinuation.yield(
              .committed(committedText)
            )
          } else {
            updateContinuation.yield(
              .provisional(
                text,
                committedText: committedText
              )
            )
          }
        }
        if lifecycle.resultEndedUnexpectedly {
          updateContinuation.finish(
            throwing:
              SpeechRecognitionBackendError
              .recognitionInterrupted
          )
        } else {
          updateContinuation.finish()
        }
      } catch is CancellationError {
        if lifecycle.cancellationWasUnexpected(
          taskIsCancelled: Task.isCancelled
        ) {
          updateContinuation.finish(
            throwing:
              SpeechRecognitionBackendError
              .recognitionInterrupted
          )
        } else {
          updateContinuation.finish()
        }
      } catch {
        updateContinuation.finish(
          throwing:
            SpeechRecognitionBackendError
            .recognitionFailed(error.localizedDescription)
        )
      }
    }

    do {
      try await analyzer.start(inputSequence: inputStream)
    } catch {
      resultTask?.cancel()
      updateContinuation.finish()
      throw
        SpeechRecognitionBackendError
        .recognitionFailed(error.localizedDescription)
    }
  }

  /// Releases the local-model reservation held by preparation.
  static func release(
    configuration: SpeechAnalyzerRecognitionConfiguration
  ) async {
    _ = await AssetInventory.release(
      reservedLocale: configuration.locale
    )
  }

  /// Creates the exact local dictation module used for preparation and runtime.
  private static func makeTranscriber(
    locale: Locale
  ) -> DictationTranscriber {
    DictationTranscriber(
      locale: locale,
      preset: .progressiveLongDictation
    )
  }

  /// Installs and reserves the requested on-device model.
  private static func ensureModel(
    for transcriber: DictationTranscriber,
    locale: Locale
  ) async throws {
    let modules: [any SpeechModule] = [transcriber]
    let initialStatus = await AssetInventory.status(
      forModules: modules
    )
    if initialStatus == .unsupported {
      throw SpeechRecognitionBackendError.localeUnsupported
    }

    if initialStatus != .installed {
      guard
        let request =
          try await AssetInventory
          .assetInstallationRequest(supporting: modules)
      else {
        throw SpeechRecognitionBackendError.modelUnavailable
      }
      try await request.downloadAndInstall()
      guard
        await AssetInventory.status(forModules: modules)
          == .installed
      else {
        throw SpeechRecognitionBackendError.modelUnavailable
      }
    }
    _ = try await AssetInventory.reserve(locale: locale)
  }
}
