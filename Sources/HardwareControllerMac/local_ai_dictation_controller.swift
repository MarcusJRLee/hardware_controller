import Foundation
import HardwareControllerCore

private enum LocalAIRefinementDeadlineOutcome: Sendable {
  case response(LocalAIRefinementResponse)
  case failure(LocalAIRefinementFailure)
  case cancelled
}

/// Resolves a deadline race without awaiting a non-cooperative provider task.
private actor LocalAIRefinementDeadlineRace {
  private var outcome: LocalAIRefinementDeadlineOutcome?
  private var continuation: CheckedContinuation<LocalAIRefinementDeadlineOutcome, Never>?

  func wait() async -> LocalAIRefinementDeadlineOutcome {
    return await withCheckedContinuation { continuation in
      if let outcome {
        continuation.resume(returning: outcome)
      } else {
        self.continuation = continuation
      }
    }
  }

  func resolve(_ outcome: LocalAIRefinementDeadlineOutcome) {
    guard self.outcome == nil else {
      return
    }
    self.outcome = outcome
    continuation?.resume(returning: outcome)
    continuation = nil
  }
}

public actor LocalAIDictationController {
  public typealias SnapshotHandler =
    @Sendable (LocalAIDictationSnapshot) -> Void

  private let speech: OwnedTranscriptionController
  private let preparedTargeter: PreparedLocalAITargeter
  private let targeter: any FocusedTextTargeting
  private let writer: any TranscriptWriting
  private let contextCapturer: any LocalAIContextCapturing
  private let refiner: any LocalAIRefinementRouting
  private let validator: RefinedTranscriptValidator
  private let polisher: DeterministicTranscriptPolisher
  private let replacementApplier: PersonalDictionaryReplacementApplier
  private let locale: Locale
  private let refinementTimeout: Duration
  private let snapshotHandler: SnapshotHandler
  private let speechMailbox: LocalAISpeechSnapshotMailbox

  private var settings: LocalAISettings
  private var profileName: String
  private var state = LocalAIDictationSnapshot.idle
  private var target: FocusedTextTarget?
  private var targetContext: LocalAITargetContext?
  private var speechSessionID: UUID?
  private var providerPreparationTask: Task<Void, any Error>?
  private var providerTestTask: Task<LocalAIRefinementFailure?, Never>?
  private var refinementTask: Task<Void, Never>?
  private var speechObservationTask: Task<Void, Never>?

  public init(
    factory: any SpeechRecognitionSessionCreating,
    microphone: any MicrophoneCapturing,
    targeter: any FocusedTextTargeting,
    writer: any TranscriptWriting,
    authorization: any TranscriptionAuthorizationProviding,
    contextCapturer: any LocalAIContextCapturing =
      AccessibilityLocalAIContextCapturer(),
    refiner: any LocalAIRefinementRouting =
      LocalAIRefinementRouter(),
    settings: LocalAISettings,
    profileName: String,
    locale: Locale = .current,
    finalizationTimeout: Duration = .seconds(5),
    refinementTimeout: Duration = .seconds(3),
    snapshotHandler: @escaping SnapshotHandler = { _ in }
  ) {
    let preparedTargeter = PreparedLocalAITargeter(
      underlying: targeter
    )
    let mailbox = LocalAISpeechSnapshotMailbox()
    speech = OwnedTranscriptionController(
      factory: factory,
      microphone: microphone,
      targeter: preparedTargeter,
      writer: DiscardingTranscriptWriter(),
      authorization: authorization,
      locale: locale,
      vocabularyHints: settings.dictionary.vocabulary,
      finalizationTimeout: finalizationTimeout,
      snapshotHandler: mailbox.publish
    )
    self.preparedTargeter = preparedTargeter
    self.targeter = targeter
    self.writer = writer
    self.contextCapturer = contextCapturer
    self.refiner = refiner
    validator = RefinedTranscriptValidator()
    polisher = DeterministicTranscriptPolisher()
    replacementApplier = PersonalDictionaryReplacementApplier()
    self.settings = settings
    self.profileName = profileName
    self.locale = locale
    self.refinementTimeout = refinementTimeout
    self.snapshotHandler = snapshotHandler
    speechMailbox = mailbox

  }

  public func handle(_ command: DictationCommand) async {
    switch command {
    case .begin:
      await begin()
    case .finish:
      await speech.handle(.finish)
    case .cancel:
      await cancel()
    }
  }

  public func snapshot() -> LocalAIDictationSnapshot {
    state
  }

  public func readiness() async -> LocalAIReadinessSnapshot {
    await refiner.readiness(settings: settings, locale: locale)
  }

  public func testProvider() async -> LocalAIRefinementFailure? {
    guard
      state.phase == .idle || state.phase == .completed
        || state.phase == .failed
    else {
      return .providerUnavailable(
        "Finish the active dictation before testing the provider."
      )
    }
    guard providerTestTask == nil else {
      return .providerUnavailable(
        "The selected local provider test is already running."
      )
    }
    let currentSettings = settings
    let task = Task<LocalAIRefinementFailure?, Never> { [weak self] in
      guard let self else {
        return LocalAIRefinementFailure.providerUnavailable(
          "The selected local provider test was canceled."
        )
      }
      return await self.performProviderTest(settings: currentSettings)
    }
    providerTestTask = task
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    providerTestTask = nil
    return result
  }

  private func performProviderTest(
    settings currentSettings: LocalAISettings
  ) async -> LocalAIRefinementFailure? {
    let preparationTask = Task { [refiner] in
      try await refiner.prepare(settings: currentSettings)
    }
    defer {
      preparationTask.cancel()
    }
    do {
      let transcript = "hardware controller local ai test"
      let request = LocalAIRefinementRequest(
        sessionID: UUID(),
        transcript: transcript,
        context: LocalAITargetContext(
          localeIdentifier: locale.identifier,
          profileName: profileName,
          applicationName: "Hardware Controller",
          applicationBundleIdentifier:
            ApplicationIdentity.bundleIdentifier,
          targetRole: "ProviderTest",
          supportsMultilineText: false,
          nearbyText: nil
        ),
        dictionary: .empty,
        additionalInstructions:
          currentSettings.additionalInstructions
      )
      let response = try await responseBeforeTimeout(
        request,
        settings: currentSettings,
        preparationTask: preparationTask
      )
      let polished = polisher.polish(
        response.text,
        preserving: transcript
      )
      _ = try validator.validate(
        polished,
        preserving: transcript,
        dictionary: .empty,
        supportsMultiline: false,
        context: request.context
      )
      return nil
    } catch is CancellationError {
      return .providerUnavailable(
        "The selected local provider test was canceled."
      )
    } catch let failure as LocalAIRefinementFailure {
      return failure
    } catch {
      return .generationFailed(
        "The selected local provider test failed."
      )
    }
  }

  public func update(
    settings: LocalAISettings,
    profileName: String
  ) async {
    let previousSettings = self.settings
    let settingsChanged = previousSettings != settings
    let contextChanged = self.profileName != profileName
    if settingsChanged || contextChanged {
      await cancel()
      await stopProviderTest()
    }
    if settingsChanged {
      await refiner.release(settings: previousSettings)
    }
    self.settings = settings
    self.profileName = profileName
    await speech.setVocabularyHints(settings.dictionary.vocabulary)
  }

  public func shutdown() async {
    await cancel()
    await stopProviderTest()
    speechObservationTask?.cancel()
    speechMailbox.finish()
    await speech.shutdown()
    await refiner.shutdown()
  }

  private func stopProviderTest() async {
    guard let task = providerTestTask else {
      return
    }
    task.cancel()
    _ = await task.value
    providerTestTask = nil
  }

  private func begin() async {
    startObservingSpeechIfNeeded()
    guard
      [.idle, .completed, .failed].contains(state.phase)
    else {
      return
    }
    do {
      try settings.validate()
    } catch {
      publishFailure(
        .refinement(
          .providerUnavailable(
            "Local AI Dictation settings are invalid."
          )
        ),
        sessionID: UUID(),
        targetApplicationName: nil
      )
      return
    }

    let capturedTarget: FocusedTextTarget
    do {
      capturedTarget = try targeter.capture()
    } catch {
      publishFailure(
        .transcription(transcriptionFailure(from: error)),
        sessionID: UUID(),
        targetApplicationName: nil
      )
      return
    }

    let sessionID = UUID()
    target = capturedTarget
    preparedTargeter.prepare(capturedTarget.finalOnlyCopy())
    state = LocalAIDictationSnapshot(
      sessionID: sessionID,
      phase: .preparing,
      volatileText: "",
      rawText: "",
      refinedText: "",
      targetApplicationName: capturedTarget.applicationName,
      failure: nil
    )
    publish()

    let currentSettings = settings
    providerPreparationTask = Task { [refiner] in
      try await refiner.prepare(settings: currentSettings)
    }
    await speech.setVocabularyHints(
      currentSettings.dictionary.vocabulary
    )
    await speech.handle(.begin)
    let initialSpeechSnapshot = await speech.snapshot()
    speechSessionID = initialSpeechSnapshot.sessionID
    guard initialSpeechSnapshot.phase != .failed else {
      await receiveSpeech(initialSpeechSnapshot)
      return
    }
    targetContext = contextCapturer.capture(
      for: capturedTarget,
      profileName: profileName,
      locale: locale,
      includeNearbyText: currentSettings.includeNearbyText
    )
    await receiveSpeech(initialSpeechSnapshot)
  }

  private func startObservingSpeechIfNeeded() {
    guard speechObservationTask == nil else {
      return
    }
    let mailbox = speechMailbox
    speechObservationTask = Task { [weak self, mailbox] in
      for await snapshot in mailbox.stream {
        await self?.receiveSpeech(snapshot)
      }
    }
  }

  private func receiveSpeech(
    _ snapshot: TranscriptionSnapshot
  ) async {
    guard
      let speechSessionID,
      snapshot.sessionID == speechSessionID,
      let sessionID = state.sessionID
    else {
      return
    }

    switch snapshot.phase {
    case .preparing:
      replace(
        phase: .preparing,
        volatileText: displayedText(snapshot),
        rawText: snapshot.finalText
      )
    case .listening:
      replace(
        phase: .listening,
        volatileText: displayedText(snapshot),
        rawText: snapshot.finalText
      )
    case .finalizing:
      replace(
        phase: .finalizing,
        volatileText: displayedText(snapshot),
        rawText: snapshot.finalText
      )
    case .canceling:
      replace(phase: .canceling, volatileText: "")
    case .failed:
      await failTranscription(
        snapshot.failure
          ?? .recognitionFailed(
            "On-device recognition did not finish."
          ),
        rawText: snapshot.finalText,
        sessionID: sessionID
      )
    case .completed:
      guard !snapshot.finalText.isEmpty else {
        await fallbackOrFail(
          reason: .invalidResponse(
            "Speech recognition returned no text."
          ),
          rawText: snapshot.finalText,
          sessionID: sessionID
        )
        return
      }
      replace(
        phase: .refining,
        volatileText: "",
        rawText: snapshot.finalText
      )
      startRefinement(
        rawText: snapshot.finalText,
        sessionID: sessionID
      )
    case .idle:
      break
    }
  }

  private func startRefinement(
    rawText: String,
    sessionID: UUID
  ) {
    guard refinementTask == nil else {
      return
    }
    refinementTask = Task { [weak self] in
      await self?.refine(rawText: rawText, sessionID: sessionID)
    }
  }

  private func refine(
    rawText: String,
    sessionID: UUID
  ) async {
    guard
      state.sessionID == sessionID,
      let targetContext
    else {
      return
    }
    let currentSettings = settings
    let preparationTask = providerPreparationTask
    let normalizedTranscript = replacementApplier.apply(
      currentSettings.dictionary,
      to: rawText
    )
    let request = LocalAIRefinementRequest(
      sessionID: sessionID,
      transcript: normalizedTranscript,
      context: targetContext,
      dictionary: currentSettings.dictionary,
      additionalInstructions:
        currentSettings.additionalInstructions
    )
    let start = MonotonicClock.nowNanoseconds()

    do {
      let response = try await responseBeforeTimeout(
        request,
        settings: currentSettings,
        preparationTask: preparationTask
      )
      guard !Task.isCancelled, state.sessionID == sessionID else {
        return
      }
      replace(phase: .validating)
      let polished = polisher.polish(
        response.text,
        preserving: normalizedTranscript
      )
      let validated = try validator.validate(
        polished,
        preserving: normalizedTranscript,
        dictionary: currentSettings.dictionary,
        supportsMultiline: targetContext.supportsMultilineText,
        context: targetContext
      )
      guard !Task.isCancelled, state.sessionID == sessionID else {
        return
      }
      replace(phase: .delivering, refinedText: validated)
      guard let target else {
        throw TranscriptionFailure.focusChanged
      }
      try writer.insert(validated, into: target)
      let duration = MonotonicClock.nowNanoseconds() - start
      state = LocalAIDictationSnapshot(
        sessionID: sessionID,
        phase: .completed,
        volatileText: "",
        rawText: rawText,
        refinedText: validated,
        targetApplicationName: target.applicationName,
        failure: nil,
        refinementNanoseconds: duration
      )
      clearSessionResources()
      publish()
    } catch is CancellationError {
      return
    } catch let failure as LocalAIRefinementFailure {
      if failure == .timedOut {
        providerPreparationTask?.cancel()
      }
      await fallbackOrFail(
        reason: failure,
        rawText: rawText,
        sessionID: sessionID
      )
    } catch {
      await failDelivery(
        transcriptionFailure(from: error),
        rawText: rawText,
        sessionID: sessionID
      )
    }
  }

  private func responseBeforeTimeout(
    _ request: LocalAIRefinementRequest,
    settings: LocalAISettings,
    preparationTask: Task<Void, any Error>? = nil
  ) async throws -> LocalAIRefinementResponse {
    let race = LocalAIRefinementDeadlineRace()
    let providerTask = Task { [refiner] in
      let outcome: LocalAIRefinementDeadlineOutcome
      do {
        let response = try await withTaskCancellationHandler {
          try await preparationTask?.value
          return try await refiner.refine(
            request,
            settings: settings
          )
        } onCancel: {
          preparationTask?.cancel()
        }
        outcome = .response(response)
      } catch is CancellationError {
        outcome = .cancelled
      } catch let failure as LocalAIRefinementFailure {
        outcome = .failure(failure)
      } catch {
        outcome = .failure(
          .generationFailed(
            "The selected local provider failed."
          )
        )
      }
      await race.resolve(outcome)
    }
    let timeoutTask = Task { [refinementTimeout] in
      do {
        try await Task.sleep(for: refinementTimeout)
        // Publish the timeout before cancellation can resolve the race.
        await race.resolve(.failure(.timedOut))
        preparationTask?.cancel()
      } catch is CancellationError {
        return
      }
    }
    let outcome = await withTaskCancellationHandler {
      await race.wait()
    } onCancel: {
      providerTask.cancel()
      timeoutTask.cancel()
      preparationTask?.cancel()
      Task {
        await race.resolve(.cancelled)
      }
    }
    providerTask.cancel()
    timeoutTask.cancel()

    switch outcome {
    case .response(let response):
      return response
    case .failure(let failure):
      throw failure
    case .cancelled:
      throw CancellationError()
    }
  }

  private func fallbackOrFail(
    reason: LocalAIRefinementFailure,
    rawText: String,
    sessionID: UUID
  ) async {
    guard state.sessionID == sessionID else {
      return
    }
    guard !rawText.isEmpty, let target else {
      publishFailure(
        .refinement(reason),
        sessionID: sessionID,
        targetApplicationName: state.targetApplicationName,
        rawText: rawText
      )
      clearSessionResources()
      return
    }
    do {
      replace(phase: .delivering, refinedText: "")
      try writer.insert(rawText, into: target)
      state = LocalAIDictationSnapshot(
        sessionID: sessionID,
        phase: .completed,
        volatileText: "",
        rawText: rawText,
        refinedText: "",
        targetApplicationName: target.applicationName,
        failure: nil,
        fallbackReason: reason
      )
      clearSessionResources()
      publish()
    } catch {
      await failDelivery(
        transcriptionFailure(from: error),
        rawText: rawText,
        sessionID: sessionID
      )
    }
  }

  private func failTranscription(
    _ failure: TranscriptionFailure,
    rawText: String,
    sessionID: UUID
  ) async {
    guard state.sessionID == sessionID else {
      return
    }
    publishFailure(
      .transcription(failure),
      sessionID: sessionID,
      targetApplicationName: state.targetApplicationName,
      rawText: rawText
    )
    clearSessionResources()
  }

  private func failDelivery(
    _ failure: TranscriptionFailure,
    rawText: String,
    sessionID: UUID
  ) async {
    guard state.sessionID == sessionID else {
      return
    }
    publishFailure(
      .delivery(failure),
      sessionID: sessionID,
      targetApplicationName: state.targetApplicationName,
      rawText: rawText,
      refinedText: state.refinedText
    )
    clearSessionResources()
  }

  private func cancel() async {
    let wasActive = [
      LocalAIDictationPhase.preparing,
      .listening,
      .finalizing,
      .refining,
      .validating,
      .delivering,
    ].contains(state.phase)
    if wasActive {
      replace(phase: .canceling, volatileText: "")
    }
    providerPreparationTask?.cancel()
    refinementTask?.cancel()
    await speech.handle(.cancel)
    speechSessionID = nil
    clearSessionResources()
    if wasActive {
      state = .idle
      publish()
    }
  }

  private func displayedText(
    _ snapshot: TranscriptionSnapshot
  ) -> String {
    var text = snapshot.finalText
    TranscriptAccumulator.append(snapshot.volatileText, to: &text)
    return text
  }

  private func replace(
    phase: LocalAIDictationPhase? = nil,
    volatileText: String? = nil,
    rawText: String? = nil,
    refinedText: String? = nil
  ) {
    state = LocalAIDictationSnapshot(
      sessionID: state.sessionID,
      phase: phase ?? state.phase,
      volatileText: volatileText ?? state.volatileText,
      rawText: rawText ?? state.rawText,
      refinedText: refinedText ?? state.refinedText,
      targetApplicationName: state.targetApplicationName,
      failure: state.failure,
      fallbackReason: state.fallbackReason,
      refinementNanoseconds: state.refinementNanoseconds
    )
    publish()
  }

  private func publishFailure(
    _ failure: LocalAIDictationFailure,
    sessionID: UUID,
    targetApplicationName: String?,
    rawText: String = "",
    refinedText: String = ""
  ) {
    state = LocalAIDictationSnapshot(
      sessionID: sessionID,
      phase: .failed,
      volatileText: "",
      rawText: rawText,
      refinedText: refinedText,
      targetApplicationName: targetApplicationName,
      failure: failure
    )
    publish()
  }

  private func transcriptionFailure(
    from error: any Error
  ) -> TranscriptionFailure {
    if let failure = error as? TranscriptionFailure {
      return failure
    }
    return .recognitionFailed(error.localizedDescription)
  }

  private func clearSessionResources() {
    target = nil
    targetContext = nil
    preparedTargeter.clear()
    providerPreparationTask = nil
    refinementTask = nil
    speechSessionID = nil
  }

  private func publish() {
    snapshotHandler(state)
  }
}

private final class PreparedLocalAITargeter:
  FocusedTextTargeting,
  @unchecked Sendable
{
  private let underlying: any FocusedTextTargeting
  private let lock = NSLock()
  private var preparedTarget: FocusedTextTarget?

  init(underlying: any FocusedTextTargeting) {
    self.underlying = underlying
  }

  func prepare(_ target: FocusedTextTarget) {
    lock.withLock {
      preparedTarget = target
    }
  }

  func clear() {
    lock.withLock {
      preparedTarget = nil
    }
  }

  func capture() throws -> FocusedTextTarget {
    try lock.withLock {
      guard let target = preparedTarget else {
        throw TranscriptionFailure.noFocusedTextField
      }
      preparedTarget = nil
      return target
    }
  }

  func isStillFocused(_ target: FocusedTextTarget) -> Bool {
    underlying.isStillFocused(target)
  }
}

private struct DiscardingTranscriptWriter: TranscriptWriting {
  func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) throws {}
}

private final class LocalAISpeechSnapshotMailbox:
  @unchecked Sendable
{
  let stream: AsyncStream<TranscriptionSnapshot>
  private let continuation: AsyncStream<TranscriptionSnapshot>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream(
      bufferingPolicy: .bufferingNewest(32)
    )
  }

  func publish(_ snapshot: TranscriptionSnapshot) {
    continuation.yield(snapshot)
  }

  func finish() {
    continuation.finish()
  }
}
