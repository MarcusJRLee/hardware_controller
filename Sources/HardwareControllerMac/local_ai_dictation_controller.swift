import Foundation
import HardwareControllerCore
import os

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
  private let spokenEditEngine: VoiceSpokenEditEngine
  private let formattedDocumentBuilder: VoiceFormattedDocumentBuilder
  private let formattedTextRenderer: VoiceFormattedTextRenderer
  private let locale: Locale
  private let refinementTimeout: Duration
  private let snapshotHandler: SnapshotHandler
  private let speechMailbox: LocalAISpeechSnapshotMailbox
  private let history: any VoiceSessionHistoryRecording
  private let now: @Sendable () -> Date
  private let logger = Logger(
    subsystem: ApplicationIdentity.bundleIdentifier,
    category: "VoiceHistory"
  )

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
  private var sessionStartedAt: Date?
  private var activeFormattedDocument: VoiceFormattedDocument?
  private var activeCanonicalFormattedText = ""

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
    history: any VoiceSessionHistoryRecording =
      DiscardingVoiceSessionHistory(),
    now: @escaping @Sendable () -> Date = { Date() },
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
      audioBufferHandler: history.append,
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
    spokenEditEngine = VoiceSpokenEditEngine()
    formattedDocumentBuilder = VoiceFormattedDocumentBuilder()
    formattedTextRenderer = VoiceFormattedTextRenderer()
    self.settings = settings
    self.profileName = profileName
    self.locale = locale
    self.refinementTimeout = refinementTimeout
    self.history = history
    self.now = now
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
          currentSettings.additionalInstructions,
        style: currentSettings.style
      )
      let response = try await responseBeforeTimeout(
        request,
        settings: currentSettings,
        preparationTask: preparationTask
      )
      let polished = polishedText(
        response.text,
        preserving: transcript,
        style: currentSettings.style
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
    let deliveryTarget: FocusedTextTarget
    do {
      deliveryTarget = try capturedTarget.guardedDeliveryCopy()
    } catch {
      publishFailure(
        .transcription(transcriptionFailure(from: error)),
        sessionID: UUID(),
        targetApplicationName: capturedTarget.applicationName
      )
      return
    }

    let sessionID = UUID()
    let startedAt = now()
    sessionStartedAt = startedAt
    history.begin(sessionID: sessionID, startedAt: startedAt)
    target = deliveryTarget
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
    if currentSettings.style.kind == .verbatim {
      providerPreparationTask = nil
    } else {
      providerPreparationTask = Task { [refiner] in
        try await refiner.prepare(settings: currentSettings)
      }
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
    let spokenEditResult = spokenEditEngine.apply(
      to: rawText
    )
    let normalizedTranscript = replacementApplier.apply(
      currentSettings.dictionary,
      to: spokenEditResult.editedText
    )
    let storedSpokenEdits =
      spokenEditResult.operations.isEmpty
      ? nil : spokenEditResult
    guard !normalizedTranscript.isEmpty else {
      providerPreparationTask?.cancel()
      await recordCompletedSession(
        sessionID: sessionID,
        rawText: rawText,
        editedText: normalizedTranscript,
        formattedText: "",
        deliveredText: "",
        targetApplicationName: targetContext.applicationName,
        deliveryOutcome: .notAttempted,
        spokenEdits: storedSpokenEdits
      )
      state = LocalAIDictationSnapshot(
        sessionID: sessionID,
        phase: .completed,
        volatileText: "",
        rawText: rawText,
        refinedText: "",
        targetApplicationName: targetContext.applicationName,
        failure: nil
      )
      clearSessionResources()
      publish()
      return
    }
    let request = LocalAIRefinementRequest(
      sessionID: sessionID,
      transcript: normalizedTranscript,
      context: targetContext,
      dictionary: currentSettings.dictionary,
      additionalInstructions:
        currentSettings.additionalInstructions,
      style: currentSettings.style
    )
    let start = MonotonicClock.nowNanoseconds()

    do {
      let response: LocalAIRefinementResponse?
      let candidate: String
      if currentSettings.style.kind == .verbatim {
        response = nil
        candidate = normalizedTranscript
      } else {
        let modelResponse = try await responseBeforeTimeout(
          request,
          settings: currentSettings,
          preparationTask: preparationTask
        )
        response = modelResponse
        candidate = polishedText(
          modelResponse.text,
          preserving: normalizedTranscript,
          style: currentSettings.style
        )
      }
      guard !Task.isCancelled, state.sessionID == sessionID else {
        return
      }
      replace(phase: .validating)
      let validated = try validator.validate(
        candidate,
        preserving: normalizedTranscript,
        dictionary: currentSettings.dictionary,
        supportsMultiline: true,
        context: targetContext
      )
      let formattedDocument = try formattedDocumentBuilder.build(
        formattedText: validated,
        rawText: rawText,
        style: currentSettings.style,
        provider: response?.provider,
        modelIdentifier: response?.modelIdentifier,
        promptRevision: response == nil
          ? nil : VersionedLocalAIPromptBuilder.currentRevision
      )
      let canonicalFormattedText = try formattedTextRenderer.render(
        formattedDocument,
        supportsMultiline: true
      )
      _ = try validator.validate(
        canonicalFormattedText,
        preserving: normalizedTranscript,
        dictionary: currentSettings.dictionary,
        supportsMultiline: true,
        context: targetContext
      )
      let deliveredText = try formattedTextRenderer.render(
        formattedDocument,
        supportsMultiline: targetContext.supportsMultilineText
      )
      guard !Task.isCancelled, state.sessionID == sessionID else {
        return
      }
      activeFormattedDocument = formattedDocument
      activeCanonicalFormattedText = canonicalFormattedText
      replace(phase: .delivering, refinedText: deliveredText)
      guard let target else {
        throw TranscriptionFailure.focusChanged
      }
      try writer.insert(deliveredText, into: target)
      let duration = MonotonicClock.nowNanoseconds() - start
      await recordCompletedSession(
        sessionID: sessionID,
        rawText: rawText,
        editedText: normalizedTranscript,
        formattedText: canonicalFormattedText,
        deliveredText: deliveredText,
        targetApplicationName: target.applicationName,
        deliveryOutcome: .inserted,
        formattedDocument: formattedDocument,
        spokenEdits: storedSpokenEdits
      )
      state = LocalAIDictationSnapshot(
        sessionID: sessionID,
        phase: .completed,
        volatileText: "",
        rawText: rawText,
        refinedText: deliveredText,
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
        sessionID: sessionID,
        editedText: normalizedTranscript,
        spokenEdits: storedSpokenEdits
      )
    } catch is VoiceFormattingError {
      await fallbackOrFail(
        reason: .invalidResponse(
          "Structured formatting validation failed."
        ),
        rawText: rawText,
        sessionID: sessionID,
        editedText: normalizedTranscript,
        spokenEdits: storedSpokenEdits
      )
    } catch {
      await failDelivery(
        transcriptionFailure(from: error),
        rawText: rawText,
        sessionID: sessionID,
        editedText: normalizedTranscript,
        spokenEdits: storedSpokenEdits
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
    sessionID: UUID,
    editedText: String? = nil,
    spokenEdits: VoiceSpokenEditResult? = nil
  ) async {
    guard state.sessionID == sessionID else {
      return
    }
    let fallbackText = editedText ?? rawText
    guard !fallbackText.isEmpty, let target else {
      await recordCompletedSession(
        sessionID: sessionID,
        rawText: rawText,
        editedText: fallbackText,
        formattedText: "",
        deliveredText: "",
        targetApplicationName: state.targetApplicationName,
        deliveryOutcome: .notAttempted,
        deliveryFailure: reason.localizedDescription,
        spokenEdits: spokenEdits
      )
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
      let fallbackDocument = try? formattedDocumentBuilder.build(
        formattedText: fallbackText,
        rawText: rawText,
        style: settings.style,
        validationStatus: .sourceFallback
      )
      let deliveredFallback = deterministicFallbackText(
        fallbackText,
        supportsMultiline: targetContext?.supportsMultilineText
          ?? target.supportsMultilineText
      )
      try writer.insert(deliveredFallback, into: target)
      await recordCompletedSession(
        sessionID: sessionID,
        rawText: rawText,
        editedText: fallbackText,
        formattedText: fallbackText,
        deliveredText: deliveredFallback,
        targetApplicationName: target.applicationName,
        deliveryOutcome: .inserted,
        formattedDocument: fallbackDocument,
        spokenEdits: spokenEdits
      )
      state = LocalAIDictationSnapshot(
        sessionID: sessionID,
        phase: .completed,
        volatileText: "",
        rawText: rawText,
        refinedText: deliveredFallback,
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
        sessionID: sessionID,
        editedText: fallbackText,
        spokenEdits: spokenEdits
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
    await recordCompletedSession(
      sessionID: sessionID,
      rawText: rawText,
      formattedText: state.refinedText,
      deliveredText: "",
      targetApplicationName: state.targetApplicationName,
      deliveryOutcome: .notAttempted,
      deliveryFailure: failure.localizedDescription,
      formattedDocument: activeFormattedDocument
    )
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
    sessionID: UUID,
    editedText: String? = nil,
    spokenEdits: VoiceSpokenEditResult? = nil
  ) async {
    guard state.sessionID == sessionID else {
      return
    }
    await recordCompletedSession(
      sessionID: sessionID,
      rawText: rawText,
      editedText: editedText,
      formattedText: activeCanonicalFormattedText.isEmpty
        ? state.refinedText : activeCanonicalFormattedText,
      deliveredText: "",
      targetApplicationName: state.targetApplicationName,
      deliveryOutcome: .failed,
      deliveryFailure: failure.localizedDescription,
      deliveryFailureReason: VoiceSessionDeliveryFailureReason(failure),
      formattedDocument: activeFormattedDocument,
      spokenEdits: spokenEdits
    )
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
    let sessionID = state.sessionID
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
    if let sessionID {
      await history.cancel(sessionID: sessionID)
    }
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
    sessionStartedAt = nil
    activeFormattedDocument = nil
    activeCanonicalFormattedText = ""
  }

  private func recordCompletedSession(
    sessionID: UUID,
    rawText: String,
    editedText: String? = nil,
    formattedText: String,
    deliveredText: String,
    targetApplicationName: String?,
    deliveryOutcome: VoiceSessionDeliveryOutcome,
    deliveryFailure: String? = nil,
    deliveryFailureReason: VoiceSessionDeliveryFailureReason? = nil,
    formattedDocument: VoiceFormattedDocument? = nil,
    spokenEdits: VoiceSpokenEditResult? = nil
  ) async {
    let document = VoiceSessionDocument(
      id: sessionID,
      startedAt: sessionStartedAt ?? now(),
      endedAt: now(),
      rawText: rawText,
      editedText: editedText ?? rawText,
      formattedText: formattedText,
      deliveredText: deliveredText,
      targetApplicationName: targetApplicationName,
      deliveryOutcome: deliveryOutcome,
      deliveryFailure: deliveryFailure,
      deliveryFailureReason: deliveryFailureReason,
      formattedDocument: formattedDocument,
      spokenEdits: spokenEdits
    )
    do {
      try await history.complete(document)
    } catch {
      logger.error("Voice History persistence failed.")
    }
  }

  private func publish() {
    snapshotHandler(state)
  }

  private func polishedText(
    _ text: String,
    preserving source: String,
    style: VoiceStyle
  ) -> String {
    switch style.kind {
    case .casualMessage, .verbatim:
      text.trimmingCharacters(in: .whitespacesAndNewlines)
    case .natural, .formal, .technical:
      polisher.polish(text, preserving: source)
    }
  }

  private func deterministicFallbackText(
    _ text: String,
    supportsMultiline: Bool
  ) -> String {
    guard !supportsMultiline else {
      return text
    }
    return text.split(
      whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" }
    ).joined(separator: " ")
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

  func ownershipFailure(
    for target: FocusedTextTarget
  ) -> FocusedTextTargetOwnershipFailure? {
    underlying.ownershipFailure(for: target)
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
