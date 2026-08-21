import Foundation
import HardwareControllerCore

public struct TranscriptionAuthorization:
  Equatable,
  Sendable
{
  public let microphone: PermissionStatus
  public let speechRecognition: PermissionStatus

  public init(
    microphone: PermissionStatus,
    speechRecognition: PermissionStatus
  ) {
    self.microphone = microphone
    self.speechRecognition = speechRecognition
  }
}

public protocol TranscriptionAuthorizationProviding:
  Sendable
{
  var current: TranscriptionAuthorization { get }
}

public struct SystemTranscriptionAuthorizationProvider:
  TranscriptionAuthorizationProviding
{
  public init() {}

  public var current: TranscriptionAuthorization {
    TranscriptionAuthorization(
      microphone: MicrophonePermission.status,
      speechRecognition:
        LegacySpeechPermission.isRequired
        ? LegacySpeechPermission.status
        : .authorized
    )
  }
}

public actor OwnedTranscriptionController {
  public typealias SnapshotHandler =
    @Sendable (TranscriptionSnapshot) -> Void

  private let factory: any SpeechRecognitionSessionCreating
  private let microphone: any MicrophoneCapturing
  private let targeter: any FocusedTextTargeting
  private let writer: any TranscriptWriting
  private let authorization: any TranscriptionAuthorizationProviding
  private let locale: Locale
  private let finalizationTimeout: Duration
  private let snapshotHandler: SnapshotHandler
  private var vocabularyHints: [String]

  private var state = TranscriptionSessionStateMachine()
  private var target: FocusedTextTarget?
  private var composition: TranscriptComposition?
  private var compositionAnchor: FocusedTextRange?
  private var recognitionSession: (any SpeechRecognitionSession)?
  private var preparationTask: Task<Void, Never>?
  private var audioTask: Task<Void, Never>?
  private var updateTask: Task<Void, Never>?
  private var finalizationTask: Task<Void, Never>?
  private var finalizationTimeoutTask: Task<Void, Never>?
  private var failureCleanupInProgress = false

  private static let unfinishedRecognitionFailure =
    TranscriptionFailure.recognitionFailed(
      "On-device recognition did not finish."
    )

  /// Creates an isolated transcription pipeline with a bounded finish deadline.
  public init(
    factory: any SpeechRecognitionSessionCreating,
    microphone: any MicrophoneCapturing,
    targeter: any FocusedTextTargeting,
    writer: any TranscriptWriting,
    authorization:
      any TranscriptionAuthorizationProviding,
    locale: Locale = .current,
    vocabularyHints: [String] = [],
    finalizationTimeout: Duration = .seconds(5),
    snapshotHandler:
      @escaping SnapshotHandler = { _ in }
  ) {
    self.factory = factory
    self.microphone = microphone
    self.targeter = targeter
    self.writer = writer
    self.authorization = authorization
    self.locale = locale
    self.finalizationTimeout = finalizationTimeout
    self.snapshotHandler = snapshotHandler
    self.vocabularyHints = vocabularyHints
  }

  public func handle(_ command: DictationCommand) async {
    switch command {
    case .begin:
      begin()
    case .finish:
      finish()
    case .cancel:
      await cancel()
    }
  }

  public func snapshot() -> TranscriptionSnapshot {
    state.snapshot
  }

  @discardableResult
  public func warmUp() async -> TranscriptionFailure? {
    let authorization = authorization.current
    guard
      authorization.microphone == .authorized,
      authorization.speechRecognition == .authorized
    else {
      return nil
    }
    do {
      async let recognition: Void =
        factory.prepare(locale: locale)
      async let audio: Void = microphone.prepare()
      _ = try await (recognition, audio)
      return nil
    } catch {
      return map(error)
    }
  }

  public func shutdown() async {
    await cancel()
    await factory.shutdown()
  }

  /// Applies bounded vocabulary to the next recognition session.
  public func setVocabularyHints(_ hints: [String]) {
    vocabularyHints = hints
  }

  /// Cancels current work before changing this app's microphone selection.
  public func selectInputDevice(uniqueID: String?) async {
    await cancel()
    await microphone.selectInputDevice(uniqueID: uniqueID)
  }

  private func begin() {
    guard
      !failureCleanupInProgress,
      [.idle, .completed, .failed]
        .contains(state.snapshot.phase)
    else {
      return
    }

    let sessionID = UUID()
    let capturedTarget: FocusedTextTarget
    do {
      capturedTarget = try targeter.capture()
    } catch {
      _ = state.apply(
        .begin(
          sessionID: sessionID,
          targetApplicationName: "Focused app",
          showsInlineProvisionalText: false
        )
      )
      failImmediately(map(error))
      return
    }

    target = capturedTarget
    if case .liveComposition(let anchor) =
      capturedTarget.deliveryCapability
    {
      composition = TranscriptComposition()
      compositionAnchor = anchor
    }
    _ = state.apply(
      .begin(
        sessionID: sessionID,
        targetApplicationName:
          capturedTarget.applicationName,
        showsInlineProvisionalText:
          capturedTarget.deliveryCapability
          .showsInlineProvisionalText
      )
    )
    publish()

    let authorization = authorization.current
    guard authorization.microphone == .authorized else {
      failImmediately(.microphonePermissionDenied)
      return
    }
    guard
      authorization.speechRecognition == .authorized
    else {
      failImmediately(
        .speechRecognitionPermissionDenied
      )
      return
    }

    preparationTask = Task {
      await prepare(sessionID: sessionID)
    }
  }

  /// Finalizes the active session after the control is released.
  private func finish() {
    guard state.apply(.finishRequested) else {
      return
    }
    publish()
    guard
      let sessionID = state.snapshot.sessionID,
      recognitionSession != nil
    else {
      return
    }
    startFinalization(sessionID: sessionID)
  }

  private func prepare(sessionID: UUID) async {
    do {
      let session: any SpeechRecognitionSession
      if !vocabularyHints.isEmpty,
        let contextualFactory =
          factory as? any ContextualSpeechRecognitionSessionCreating
      {
        session = try await contextualFactory.makeSession(
          locale: locale,
          vocabularyHints: vocabularyHints
        )
      } else {
        session = try await factory.makeSession(locale: locale)
      }
      guard isCurrent(sessionID) else {
        await session.cancel()
        return
      }

      let audioStream = try await microphone.start()
      guard isCurrent(sessionID) else {
        await microphone.stop()
        await session.cancel()
        return
      }

      recognitionSession = session
      startUpdateConsumer(
        session,
        sessionID: sessionID
      )
      startAudioConsumer(
        audioStream,
        session: session,
        sessionID: sessionID
      )
      if state.snapshot.phase == .preparing {
        _ = state.apply(.listeningStarted)
        publish()
      } else if state.snapshot.phase == .finalizing {
        startFinalization(sessionID: sessionID)
      }
    } catch is CancellationError {
      guard !Task.isCancelled, isCurrent(sessionID) else {
        return
      }
      await fail(
        Self.unfinishedRecognitionFailure,
        sessionID: sessionID
      )
    } catch {
      await fail(map(error), sessionID: sessionID)
    }
  }

  private func startUpdateConsumer(
    _ session: any SpeechRecognitionSession,
    sessionID: UUID
  ) {
    updateTask = Task {
      do {
        for try await update in session.updates {
          await receive(
            update,
            sessionID: sessionID
          )
        }
        guard !Task.isCancelled else {
          return
        }
        await updateStreamEnded(sessionID: sessionID)
      } catch is CancellationError {
        guard !Task.isCancelled else {
          return
        }
        await fail(
          Self.unfinishedRecognitionFailure,
          sessionID: sessionID
        )
      } catch {
        await fail(
          map(error),
          sessionID: sessionID
        )
      }
    }
  }

  private func startAudioConsumer(
    _ stream:
      AsyncThrowingStream<CapturedAudioBuffer, any Error>,
    session: any SpeechRecognitionSession,
    sessionID: UUID
  ) {
    audioTask = Task {
      do {
        for try await audio in stream {
          try await session.append(audio)
        }
        guard !Task.isCancelled else {
          return
        }
        await audioStreamEnded(sessionID: sessionID)
      } catch is CancellationError {
        guard !Task.isCancelled else {
          return
        }
        await fail(
          Self.unfinishedRecognitionFailure,
          sessionID: sessionID
        )
      } catch {
        await fail(
          map(error),
          sessionID: sessionID
        )
      }
    }
  }

  /// Fails when recognition stops before finalization owns termination.
  private func updateStreamEnded(sessionID: UUID) async {
    guard
      isCurrent(sessionID),
      state.snapshot.phase != .finalizing
    else {
      return
    }
    await fail(
      Self.unfinishedRecognitionFailure,
      sessionID: sessionID
    )
  }

  /// Fails when microphone delivery stops before finalization stops it.
  private func audioStreamEnded(sessionID: UUID) async {
    guard
      isCurrent(sessionID),
      state.snapshot.phase != .finalizing
    else {
      return
    }
    await fail(
      .audioUnavailable(
        "Microphone audio stopped unexpectedly."
      ),
      sessionID: sessionID
    )
  }

  private func receive(
    _ revision: TranscriptRevision,
    sessionID: UUID
  ) async {
    guard isCurrent(sessionID) else {
      return
    }

    let priorFinalText = state.snapshot.finalText
    guard state.apply(.transcript(revision)) else {
      return
    }
    publish()

    if var composition,
      let compositionAnchor,
      let target
    {
      do {
        if let mutation = try composition.apply(revision) {
          try writer.replace(
            mutation,
            anchoredAt: compositionAnchor,
            in: target
          )
        }
        self.composition = composition
      } catch {
        await fail(map(error), sessionID: sessionID)
      }
      return
    }

    if let target,
      case .bufferedEvent = target.deliveryCapability
    {
      return
    }

    let accumulated = state.snapshot.finalText
    guard accumulated.hasPrefix(priorFinalText) else {
      await fail(
        .recognitionFailed(
          "Committed transcription changed unexpectedly."
        ),
        sessionID: sessionID
      )
      return
    }
    let insertion =
      String(accumulated.dropFirst(priorFinalText.count))
    guard !insertion.isEmpty, let target else {
      return
    }
    do {
      try writer.insert(insertion, into: target)
    } catch {
      await fail(map(error), sessionID: sessionID)
    }
  }

  /// Starts finalization and its independent fail-safe deadline once.
  private func startFinalization(sessionID: UUID) {
    guard
      finalizationTask == nil,
      isCurrent(sessionID),
      state.snapshot.phase == .finalizing,
      recognitionSession != nil
    else {
      return
    }

    finalizationTask = Task {
      await finalize(sessionID: sessionID)
    }
    finalizationTimeoutTask = Task {
      do {
        try await Task.sleep(for: finalizationTimeout)
      } catch {
        return
      }
      await fail(
        Self.unfinishedRecognitionFailure,
        sessionID: sessionID
      )
    }
  }

  private func finalize(sessionID: UUID) async {
    guard
      isCurrent(sessionID),
      state.snapshot.phase == .finalizing,
      let session = recognitionSession
    else {
      return
    }

    await microphone.stop()
    await audioTask?.value
    guard
      isCurrent(sessionID),
      state.snapshot.phase == .finalizing
    else {
      return
    }

    do {
      try await session.finish()
      await updateTask?.value
      guard
        isCurrent(sessionID),
        state.snapshot.phase == .finalizing
      else {
        return
      }

      if let target,
        case .bufferedEvent = target.deliveryCapability,
        !state.snapshot.finalText.isEmpty
      {
        do {
          try writer.insert(
            state.snapshot.finalText,
            into: target
          )
        } catch {
          await fail(map(error), sessionID: sessionID)
          return
        }
      }

      _ = state.apply(.completed)
      finalizationTimeoutTask?.cancel()
      clearSession()
      publish()
    } catch is CancellationError {
      guard isCurrent(sessionID) else {
        return
      }
      await fail(
        Self.unfinishedRecognitionFailure,
        sessionID: sessionID
      )
    } catch {
      await fail(map(error), sessionID: sessionID)
    }
  }

  private func cancel() async {
    guard state.apply(.cancelRequested) else {
      return
    }
    publish()

    var cancellationFailure: TranscriptionFailure?
    if var composition,
      let compositionAnchor,
      let target
    {
      do {
        if let mutation = composition.cancel() {
          try writer.replace(
            mutation,
            anchoredAt: compositionAnchor,
            in: target
          )
        }
      } catch {
        cancellationFailure = map(error)
      }
    }

    preparationTask?.cancel()
    audioTask?.cancel()
    updateTask?.cancel()
    await microphone.stop()
    await recognitionSession?.cancel()
    finalizationTimeoutTask?.cancel()
    finalizationTask?.cancel()
    clearSession()
    if let cancellationFailure {
      _ = state.apply(.failed(cancellationFailure))
    } else {
      _ = state.apply(.cancelled)
    }
    publish()
  }

  private func fail(
    _ failure: TranscriptionFailure,
    sessionID: UUID
  ) async {
    guard isCurrent(sessionID) else {
      return
    }
    guard state.apply(.failed(failure)) else {
      return
    }
    failureCleanupInProgress = true
    publish()
    preparationTask?.cancel()
    audioTask?.cancel()
    updateTask?.cancel()
    await microphone.stop()
    await recognitionSession?.cancel()
    finalizationTimeoutTask?.cancel()
    finalizationTask?.cancel()
    clearSession()
  }

  private func failImmediately(
    _ failure: TranscriptionFailure
  ) {
    guard state.apply(.failed(failure)) else {
      return
    }
    clearSession()
    publish()
  }

  private func isCurrent(_ sessionID: UUID) -> Bool {
    state.snapshot.sessionID == sessionID
      && [
        TranscriptionPhase.preparing,
        .listening,
        .finalizing,
      ].contains(state.snapshot.phase)
  }

  private func clearSession() {
    target = nil
    composition = nil
    compositionAnchor = nil
    recognitionSession = nil
    preparationTask = nil
    audioTask = nil
    updateTask = nil
    finalizationTask = nil
    finalizationTimeoutTask = nil
    failureCleanupInProgress = false
  }

  private func publish() {
    snapshotHandler(state.snapshot)
  }

  private func map(
    _ error: any Error
  ) -> TranscriptionFailure {
    if let failure = error as? TranscriptionFailure {
      return failure
    }
    if let composition =
      error as? TranscriptCompositionFailure
    {
      switch composition {
      case .committedTextChanged:
        return .recognitionFailed(
          "Committed transcription changed unexpectedly."
        )
      }
    }
    if let backend = error as? SpeechRecognitionBackendError {
      switch backend {
      case .localeUnsupported:
        return .localeUnsupported
      case .modelUnavailable:
        return .modelUnavailable
      case .conversionFailed(let message),
        .recognitionFailed(let message):
        return .recognitionFailed(message)
      case .recognitionInterrupted:
        return Self.unfinishedRecognitionFailure
      case .unavailable:
        return .recognitionFailed(
          "On-device speech recognition is unavailable."
        )
      }
    }
    if let capture = error as? MicrophoneCaptureError {
      switch capture {
      case .noInputDevice:
        return .audioUnavailable(
          "No microphone input is available."
        )
      case .alreadyRunning:
        return .audioUnavailable(
          "The microphone is already in use."
        )
      case .inputConfigurationChanged:
        return .audioUnavailable(
          "The microphone input changed. Try Dictation again."
        )
      case .couldNotMonitorInput(let message):
        return .audioUnavailable(message)
      case .bufferOverflow:
        return .audioUnavailable(
          "The app could not keep up with microphone audio."
        )
      case .invalidBuffer(let message):
        return .audioUnavailable(message)
      case .couldNotStart(let message):
        return .audioUnavailable(message)
      }
    }
    return .recognitionFailed(error.localizedDescription)
  }
}

public final class OwnedTranscriptionCommandDispatcher:
  DictationCommandDispatching,
  @unchecked Sendable
{
  private let dispatcher: AsyncDictationCommandDispatcher

  public init(controller: OwnedTranscriptionController) {
    dispatcher = AsyncDictationCommandDispatcher(
      handler: { [controller] command in
        await controller.handle(command)
      },
      onShutdown: { [controller] in
        await controller.shutdown()
      }
    )
  }

  public func submit(_ command: DictationCommand) -> Bool {
    dispatcher.submit(command)
  }

  public func shutdown() {
    dispatcher.shutdown()
  }

  public func shutdownAndWait() async {
    await dispatcher.shutdownAndWait()
  }
}
