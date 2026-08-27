import AVFoundation
@preconcurrency import ApplicationServices
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct LocalAIDictationControllerTest {
  @Test
  func storesDeliveredDictationWithPlayableAudio() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
    }
    let history = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory
    )
    let fixture = LocalAIControllerFixture(
      refinement: .output("send the revised plan tomorrow")
    )
    let capturedAt = Date(timeIntervalSince1970: 1_000)
    let controller = fixture.makeController(
      history: history,
      now: { capturedAt }
    )

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.microphone.emit(try makeVoiceAudioFixture())
    fixture.session.emit(.committed("send the revised plan tomorrow"))
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    let sessions = try await history.recentSessions(limit: 10)
    let session = try #require(sessions.first)
    #expect(sessions.count == 1)
    #expect(fixture.writer.inserted == ["Send the revised plan tomorrow."])
    #expect(session.rawText == "send the revised plan tomorrow")
    #expect(session.editedText == "send the revised plan tomorrow")
    #expect(session.formattedText == "Send the revised plan tomorrow.")
    #expect(session.deliveredText == "Send the revised plan tomorrow.")
    #expect(session.deliveryOutcome == .inserted)
    #expect(session.document.startedAt == capturedAt)
    #expect(session.document.endedAt == capturedAt)
    let audioURL = try #require(session.audioArtifactURL)
    let audioFile = try AVAudioFile(forReading: audioURL)
    #expect(audioFile.length > 0)
  }

  @Test
  func failedInsertionKeepsCopyableTextAndPlayableAudio() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_failed_\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
    }
    let history = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory
    )
    let fixture = LocalAIControllerFixture(
      refinement: .output("keep this revised plan"),
      writerFailure: .focusChanged
    )
    let controller = fixture.makeController(history: history)

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.microphone.emit(try makeVoiceAudioFixture())
    fixture.session.emit(.committed("keep this revised plan"))
    await controller.handle(.finish)
    try await localAIWaitUntil {
      await controller.snapshot().phase == .failed
    }

    let sessions = try await history.recentSessions(limit: 10)
    let session = try #require(sessions.first)
    #expect(sessions.count == 1)
    #expect(session.rawText == "keep this revised plan")
    #expect(session.formattedText == "Keep this revised plan.")
    #expect(session.deliveredText.isEmpty)
    #expect(session.deliveryOutcome == .failed)
    #expect(session.document.deliveryFailureReason == .focusChanged)
    let audioURL = try #require(session.audioArtifactURL)
    #expect(try AVAudioFile(forReading: audioURL).length > 0)
  }

  @Test
  func asrLossKeepsRecoverableAudioWithoutModifyingTarget() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_asr_loss_\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
    }
    let history = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory
    )
    let fixture = LocalAIControllerFixture(
      refinement: .output("Never generated.")
    )
    let controller = fixture.makeController(history: history)

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.microphone.emit(try makeVoiceAudioFixture())
    try await localAIWaitUntil {
      fixture.session.appendCount == 1
    }
    fixture.session.fail(
      SpeechRecognitionBackendError.modelUnavailable
    )
    try await localAIWaitUntil {
      await controller.snapshot().phase == .failed
    }

    let sessions = try await history.recentSessions(limit: 10)
    let session = try #require(sessions.first)
    #expect(sessions.count == 1)
    #expect(session.rawText.isEmpty)
    #expect(session.editedText.isEmpty)
    #expect(session.formattedText.isEmpty)
    #expect(session.deliveredText.isEmpty)
    #expect(session.deliveryOutcome == .notAttempted)
    #expect(fixture.writer.inserted.isEmpty)
    #expect(await fixture.refiner.requests.isEmpty)
    let audioURL = try #require(session.audioArtifactURL)
    #expect(try AVAudioFile(forReading: audioURL).length > 0)
  }

  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_RUN_LOCAL_AI_END_TO_END_BENCHMARK"
        ] == "1"
    )
  )
  func measuresWarmReleaseToInsertionWithTheRecommendedModel() async throws {
    let sharedRefiner = LocalAIRefinementRouter(
      ollama: OllamaLocalAIRefiner()
    )
    let refiner = BenchmarkRetainedRefinementRouter(
      underlying: sharedRefiner
    )
    var settings = LocalAISettings.default
    settings.provider = .ollama
    settings.modelRetention = .processLifetime
    try await sharedRefiner.prepare(settings: settings)
    var samples: [UInt64] = []

    for evaluationCase in LocalAIEvaluationCorpus.cases {
      let fixture = LocalAIControllerFixture(refinement: .output("Unused."))
      let controller = fixture.makeController(
        settings: settings,
        refiner: refiner
      )
      await controller.handle(.begin)
      try await fixture.waitUntilListening(controller)
      fixture.session.emit(.committed(evaluationCase.transcript))
      let start = MonotonicClock.nowNanoseconds()
      await controller.handle(.finish)
      try await localAIWaitUntil(timeout: .seconds(4)) {
        await controller.snapshot().phase == .completed
      }
      let end = MonotonicClock.nowNanoseconds()
      samples.append(end >= start ? end - start : 0)
      #expect(fixture.writer.inserted.count == 1)
      await controller.shutdown()
    }
    await sharedRefiner.shutdown()

    let report = try #require(LocalAIEndToEndLatency(samples))
    print("LOCAL_AI_END_TO_END_LATENCY \(report.description)")
    #expect(report.p95Nanoseconds <= 1_500_000_000)
  }

  @Test
  func providerTestUsesOnlySanitizedModelWork() async {
    let fixture = LocalAIControllerFixture(
      refinement: .output("hardware controller local ai test")
    )
    let controller = fixture.makeController()

    let failure = await controller.testProvider()

    #expect(failure == nil)
    #expect(fixture.microphone.startCount == 0)
    #expect(fixture.writer.inserted.isEmpty)
  }

  @Test
  func nonemptyCapturedSelectionNeverStartsAudioOrFormatting() async {
    let fixture = LocalAIControllerFixture(
      refinement: .output("Never use this")
    )
    let controller = fixture.makeController(
      selectedRange: FocusedTextRange(location: 4, length: 2)
    )

    await controller.handle(.begin)

    let snapshot = await controller.snapshot()
    #expect(snapshot.phase == .failed)
    #expect(
      snapshot.failure == .transcription(.noFocusedTextField)
    )
    #expect(fixture.microphone.startCount == 0)
    #expect(await fixture.refiner.preparationCount == 0)
    #expect(fixture.writer.inserted.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func providerTestBoundsPreparationAndGenerationTogether() async {
    let fixture = LocalAIControllerFixture(
      refinement: .output("Unused."),
      preparationDelay: .seconds(1)
    )
    let controller = fixture.makeController(
      refinementTimeout: .milliseconds(20)
    )

    let failure = await controller.testProvider()

    #expect(failure == .timedOut)
    await fixture.refiner.waitUntilPreparationCancelled()
    #expect(await fixture.refiner.wasPreparationCancelled)
  }

  @Test
  func settingsAndShutdownReleaseProviderResources() async {
    let fixture = LocalAIControllerFixture(
      refinement: .output("Unused.")
    )
    let controller = fixture.makeController()
    var settings = LocalAISettings.default
    settings.provider = .ollama

    await controller.update(settings: settings, profileName: "Coding")
    await controller.shutdown()

    #expect(await fixture.refiner.releasedSettings == [.default])
    #expect(await fixture.refiner.shutdownCount == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func shutdownCancelsAnActiveProviderTestBeforeReleasingResources()
    async throws
  {
    let fixture = LocalAIControllerFixture(
      refinement: .output("Unused."),
      preparationDelay: .seconds(1)
    )
    let controller = fixture.makeController()
    let testTask = Task {
      await controller.testProvider()
    }
    try await localAIWaitUntil {
      await fixture.refiner.preparationCount == 1
    }

    await controller.shutdown()
    let failure = await testTask.value

    #expect(
      failure
        == .providerUnavailable(
          "The selected local provider test was canceled."
        )
    )
    await fixture.refiner.waitUntilPreparationCancelled()
    #expect(await fixture.refiner.wasPreparationCancelled)
    #expect(await fixture.refiner.shutdownCount == 1)
  }

  @Test
  func profileChangeCancelsAProviderTestWithoutReleasingItsModel() async throws {
    let fixture = LocalAIControllerFixture(
      refinement: .output("Unused."),
      preparationDelay: .seconds(1)
    )
    let controller = fixture.makeController()
    let testTask = Task {
      await controller.testProvider()
    }
    try await localAIWaitUntil {
      await fixture.refiner.preparationCount == 1
    }

    await controller.update(
      settings: .default,
      profileName: "Writing"
    )

    #expect(
      await testTask.value
        == .providerUnavailable(
          "The selected local provider test was canceled."
        )
    )
    #expect(await fixture.refiner.releasedSettings.isEmpty)
  }

  @Test
  func permissionLossAtBeginPublishesFailureWithoutStartingAudio() async throws {
    let fixture = LocalAIControllerFixture(
      refinement: .output("Unused.")
    )
    let controller = fixture.makeController(
      authorization: LocalAIFixedAuthorization(
        current: TranscriptionAuthorization(
          microphone: .denied,
          speechRecognition: .authorized
        )
      )
    )

    await controller.handle(.begin)
    try await localAIWaitUntil {
      await controller.snapshot().phase == .failed
    }

    #expect(fixture.microphone.startCount == 0)
    #expect(
      await controller.snapshot().failure
        == .transcription(.microphonePermissionDenied)
    )
  }

  @Test
  func refinesOnceAndForwardsRecognitionVocabulary() async throws {
    let fixture = LocalAIControllerFixture(
      refinement: .output("use HardwareControllerCore")
    )
    let controller = fixture.makeController(
      settings: LocalAISettings(
        dictionary: PersonalDictionary(
          vocabulary: ["HardwareControllerCore"]
        )
      )
    )

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(.committed("use hardware controller core"))
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    let snapshot = await controller.snapshot()
    #expect(snapshot.rawText == "use hardware controller core")
    #expect(snapshot.refinedText == "Use HardwareControllerCore.")
    #expect(fixture.writer.inserted == ["Use HardwareControllerCore."])
    #expect(fixture.factory.vocabularyHints == [["HardwareControllerCore"]])
  }

  @Test
  func storesStructuredFormattingAndRendersSingleLineTargetsSafely()
    async throws
  {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_formatting_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let fixture = LocalAIControllerFixture(
      refinement: .output(
        "Plan.\n\n- Keep Bash.\n- Keep https://example.com."
      )
    )
    var settings = LocalAISettings.default
    settings.style = .technical
    let controller = fixture.makeController(
      settings: settings,
      supportsMultilineText: false,
      history: history
    )

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(
      .committed("plan keep Bash keep https://example.com")
    )
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    let item = try #require(
      try await history.recentSessions(limit: 1).first
    )
    #expect(
      item.formattedText
        == "Plan.\n\n- Keep Bash.\n- Keep https://example.com."
    )
    #expect(
      item.deliveredText
        == "Plan. Keep Bash.; Keep https://example.com."
    )
    #expect(item.formattedDocument?.style == .technical)
    #expect(item.formattedDocument?.blocks.count == 2)
    #expect(item.formattedDocument?.validationStatus == .validated)
  }

  @Test
  func modelOrdinalProseIsNormalizedBeforeDelivery() async throws {
    let fixture = LocalAIControllerFixture(
      refinement: .output(
        "There are three steps: first, stop the service; second, copy the backup; third, restart the service."
      )
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(
      .committed(
        "there are three steps first stop the service second copy the backup third restart the service"
      )
    )
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    #expect(
      fixture.writer.inserted == [
        "There are three steps:\n\n1. stop the service\n2. copy the backup\n3. restart the service."
      ])
  }

  @Test
  func verbatimStyleBypassesTheGenerativeModel() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_verbatim_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let fixture = LocalAIControllerFixture(refinement: .output("Changed."))
    var settings = LocalAISettings.default
    settings.style = .verbatim
    let controller = fixture.makeController(
      settings: settings,
      history: history
    )

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(.committed("um keep this exactly"))
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    #expect(fixture.writer.inserted == ["um keep this exactly"])
    #expect(await fixture.refiner.preparationCount == 0)
    #expect(await fixture.refiner.refinementCompletionCount == 0)
    let item = try #require(
      try await history.recentSessions(limit: 1).first
    )
    #expect(item.formattedDocument?.style == .verbatim)
    #expect(item.formattedDocument?.validationStatus == .validated)
  }

  @Test
  func appliesSpokenEditsBeforeFormattingAndStoresTheirTrace() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_spoken_edits_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let rawText =
      "Keep this. Wrong scratch that Right new paragraph start a numbered list First new paragraph Second end list Done."
    let editedText =
      "Keep this. Right\n\n1. First\n2. Second\n\nDone."
    let fixture = LocalAIControllerFixture(
      refinement: .output(editedText)
    )
    let controller = fixture.makeController(history: history)

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(.committed(rawText))
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    let request = try #require(await fixture.refiner.requests.first)
    let item = try #require(
      try await history.recentSessions(limit: 1).first
    )
    let spokenEdits = try #require(item.document.spokenEdits)
    #expect(request.transcript == editedText)
    #expect(item.rawText == rawText)
    #expect(item.editedText == editedText)
    #expect(spokenEdits.editedText == editedText)
    #expect(spokenEdits.operations.count == 5)
    #expect(
      try VoiceSpokenEditReplayer().replay(spokenEdits)
        == item.editedText
    )
  }

  @Test
  func dictionaryReplacementCannotSynthesizeADestructiveCommand()
    async throws
  {
    let fixture = LocalAIControllerFixture(refinement: .output("Unused."))
    var settings = LocalAISettings.default
    settings.style = .verbatim
    settings.dictionary = PersonalDictionary(
      replacements: [
        PersonalDictionaryReplacement(
          spokenForm: "backtrack",
          replacement: "scratch that"
        )
      ]
    )
    let controller = fixture.makeController(settings: settings)

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(.committed("Keep backtrack as literal text"))
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    #expect(fixture.writer.inserted == ["Keep scratch that as literal text"])
    #expect(await fixture.refiner.requests.isEmpty)
  }

  @Test
  func formattingFallbackStillHonorsExplicitSpokenEdits() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_spoken_edit_fallback_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let fixture = LocalAIControllerFixture(
      refinement: .failure(.providerUnavailable("No formatter."))
    )
    let controller = fixture.makeController(history: history)

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(
      .committed("Wrong scratch that Right new paragraph Next")
    )
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    let item = try #require(
      try await history.recentSessions(limit: 1).first
    )
    #expect(fixture.writer.inserted == ["Right\n\nNext"])
    #expect(item.rawText == "Wrong scratch that Right new paragraph Next")
    #expect(item.editedText == "Right\n\nNext")
    #expect(item.formattedText == "Right\n\nNext")
    #expect(item.document.spokenEdits?.operations.count == 2)
  }

  @Test
  func fullyScratchedSessionCompletesWithoutFormattingOrInsertion()
    async throws
  {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_spoken_edit_empty_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let fixture = LocalAIControllerFixture(refinement: .output("Unused."))
    let controller = fixture.makeController(history: history)

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(.committed("Only thought scratch that"))
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    let item = try #require(
      try await history.recentSessions(limit: 1).first
    )
    #expect(fixture.writer.inserted.isEmpty)
    #expect(await fixture.refiner.requests.isEmpty)
    #expect(item.rawText == "Only thought scratch that")
    #expect(item.editedText.isEmpty)
    #expect(item.formattedText.isEmpty)
    #expect(item.deliveredText.isEmpty)
    #expect(item.deliveryOutcome == .notAttempted)
    #expect(item.document.spokenEdits?.operations.count == 1)
  }

  @Test
  func refinementFailureInsertsRawTranscriptExactlyOnce() async throws {
    let fixture = LocalAIControllerFixture(
      refinement: .failure(.providerUnavailable("Ollama is not running."))
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(.committed("keep the raw text"))
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    let snapshot = await controller.snapshot()
    #expect(fixture.writer.inserted == ["keep the raw text"])
    #expect(snapshot.refinedText == "keep the raw text")
    #expect(
      snapshot.fallbackReason
        == .providerUnavailable("Ollama is not running.")
    )
  }

  @Test
  func remoteCapableFormatterFallsBackWithoutReceivingVoiceContent()
    async throws
  {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_remote_fallback_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let remote = RemoteCapableRefinerProbe()
    let router = LocalAIRefinementRouter(ollama: remote)
    let fixture = LocalAIControllerFixture(refinement: .output("Unused."))
    var settings = LocalAISettings.default
    settings.provider = .ollama
    let controller = fixture.makeController(
      settings: settings,
      refiner: router,
      history: history
    )

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.microphone.emit(try makeVoiceAudioFixture())
    fixture.session.emit(.committed("keep this content local"))
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    let item = try #require(
      try await history.recentSessions(limit: 1).first
    )
    #expect(fixture.writer.inserted == ["keep this content local"])
    #expect(await remote.invocationCount == 0)
    #expect(item.formattedText == "keep this content local")
    #expect(item.deliveredText == "keep this content local")
    #expect(item.deliveryOutcome == .inserted)
    #expect(await controller.snapshot().fallbackReason == .remoteProviderRejected)
    let audioURL = try #require(item.audioArtifactURL)
    #expect(try AVAudioFile(forReading: audioURL).length > 0)
  }

  @Test
  func editedFallbackFlattensOnlyForASingleLineTarget() async throws {
    let fixture = LocalAIControllerFixture(
      refinement: .failure(.providerUnavailable("No formatter."))
    )
    let controller = fixture.makeController(supportsMultilineText: false)

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(.committed("first line\nsecond line"))
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    #expect(fixture.writer.inserted == ["first line second line"])
  }

  @Test
  func timeoutFallsBackWithinTheConfiguredDeadline() async throws {
    let fixture = LocalAIControllerFixture(
      refinement: .delayedOutput("Too late.", .seconds(1))
    )
    let controller = fixture.makeController(
      refinementTimeout: .milliseconds(20)
    )

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(.committed("time bounded"))
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    #expect(fixture.writer.inserted == ["time bounded"])
    #expect(await controller.snapshot().fallbackReason == .timedOut)
  }

  @Test
  func nonCooperativeLateResultCannotDelayOrDuplicateFallback() async throws {
    let fixture = LocalAIControllerFixture(
      refinement: .nonCooperativeDelayedOutput(
        "Too late.",
        .milliseconds(100)
      )
    )
    let controller = fixture.makeController(
      refinementTimeout: .milliseconds(10)
    )

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(.committed("time bounded"))
    let clock = ContinuousClock()
    let start = clock.now
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)
    let elapsed = start.duration(to: clock.now)
    try await Task.sleep(for: .milliseconds(120))

    #expect(elapsed < .milliseconds(200))
    #expect(fixture.writer.inserted == ["time bounded"])
    #expect(await fixture.refiner.refinementCompletionCount == 1)
    #expect(await controller.snapshot().refinedText == "time bounded")
    #expect(await controller.snapshot().fallbackReason == .timedOut)
  }

  @Test(.timeLimit(.minutes(1)))
  func unfinishedPreparationSharesTheRefinementDeadline() async throws {
    let fixture = LocalAIControllerFixture(
      refinement: .output("Too late."),
      preparationDelay: .seconds(1)
    )
    let controller = fixture.makeController(
      refinementTimeout: .milliseconds(20)
    )

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(.committed("time bounded"))
    await controller.handle(.finish)
    try await fixture.waitUntilCompleted(controller)

    #expect(fixture.writer.inserted == ["time bounded"])
    #expect(await controller.snapshot().fallbackReason == .timedOut)
    await fixture.refiner.waitUntilPreparationCancelled()
    #expect(await fixture.refiner.wasPreparationCancelled)
  }

  @Test
  func cancellationDuringRefinementNeverInserts() async throws {
    let fixture = LocalAIControllerFixture(
      refinement: .delayedOutput("Do not insert.", .seconds(1))
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await fixture.waitUntilListening(controller)
    fixture.session.emit(.committed("cancel this"))
    await controller.handle(.finish)
    try await localAIWaitUntil {
      await controller.snapshot().phase == .refining
    }
    await controller.handle(.cancel)
    try await Task.sleep(for: .milliseconds(30))

    #expect(await controller.snapshot().phase == .idle)
    #expect(fixture.writer.inserted.isEmpty)
  }
}

private struct BenchmarkRetainedRefinementRouter:
  LocalAIRefinementRouting
{
  let underlying: any LocalAIRefinementRouting

  func readiness(
    settings: LocalAISettings,
    locale: Locale
  ) async -> LocalAIReadinessSnapshot {
    await underlying.readiness(settings: settings, locale: locale)
  }

  func prepare(settings: LocalAISettings) async throws {
    try await underlying.prepare(settings: settings)
  }

  func refine(
    _ request: LocalAIRefinementRequest,
    settings: LocalAISettings
  ) async throws -> LocalAIRefinementResponse {
    try await underlying.refine(request, settings: settings)
  }

  func release(settings: LocalAISettings) async {}

  func shutdown() async {}
}

private final class LocalAIControllerFixture: @unchecked Sendable {
  let session = LocalAIFakeRecognitionSession()
  let microphone = LocalAIFakeMicrophone()
  let writer: LocalAIRecordingWriter
  let factory: LocalAIFakeRecognitionFactory
  let refiner: LocalAIFakeRefinementRouter

  init(
    refinement: LocalAIFakeRefinementRouter.Behavior,
    preparationDelay: Duration? = nil,
    writerFailure: TranscriptionFailure? = nil
  ) {
    writer = LocalAIRecordingWriter(failure: writerFailure)
    factory = LocalAIFakeRecognitionFactory(session: session)
    refiner = LocalAIFakeRefinementRouter(
      behavior: refinement,
      preparationDelay: preparationDelay
    )
  }

  func makeController(
    settings: LocalAISettings = .default,
    refinementTimeout: Duration = .seconds(3),
    refiner: (any LocalAIRefinementRouting)? = nil,
    authorization: any TranscriptionAuthorizationProviding =
      LocalAIFixedAuthorization(),
    supportsMultilineText: Bool = true,
    selectedRange: FocusedTextRange? = FocusedTextRange(
      location: 0,
      length: 0
    ),
    history: any VoiceSessionHistoryRecording =
      DiscardingVoiceSessionHistory(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) -> LocalAIDictationController {
    LocalAIDictationController(
      factory: factory,
      microphone: microphone,
      targeter: LocalAIFixedTargeter(
        supportsMultilineText: supportsMultilineText,
        selectedRange: selectedRange
      ),
      writer: writer,
      authorization: authorization,
      contextCapturer: LocalAIFixedContextCapturer(),
      refiner: refiner ?? self.refiner,
      settings: settings,
      profileName: "Coding",
      refinementTimeout: refinementTimeout,
      history: history,
      now: now
    )
  }

  func waitUntilListening(
    _ controller: LocalAIDictationController
  ) async throws {
    try await localAIWaitUntil {
      await controller.snapshot().phase == .listening
    }
  }

  func waitUntilCompleted(
    _ controller: LocalAIDictationController
  ) async throws {
    try await localAIWaitUntil {
      await controller.snapshot().phase == .completed
    }
  }
}

private struct LocalAIEndToEndLatency {
  let sampleCount: Int
  let p50Nanoseconds: UInt64
  let p95Nanoseconds: UInt64
  let p99Nanoseconds: UInt64
  let maximumNanoseconds: UInt64

  init?(_ samples: [UInt64]) {
    let sorted = samples.sorted()
    guard let maximum = sorted.last else {
      return nil
    }
    sampleCount = sorted.count
    p50Nanoseconds = Self.percentile(0.50, sorted: sorted)
    p95Nanoseconds = Self.percentile(0.95, sorted: sorted)
    p99Nanoseconds = Self.percentile(0.99, sorted: sorted)
    maximumNanoseconds = maximum
  }

  var description: String {
    "n=\(sampleCount) p50_ns=\(p50Nanoseconds) p95_ns=\(p95Nanoseconds) p99_ns=\(p99Nanoseconds) max_ns=\(maximumNanoseconds)"
  }

  private static func percentile(
    _ percentile: Double,
    sorted: [UInt64]
  ) -> UInt64 {
    let rank = Int(ceil(percentile * Double(sorted.count))) - 1
    return sorted[max(0, min(rank, sorted.count - 1))]
  }
}

private struct LocalAIFixedAuthorization:
  TranscriptionAuthorizationProviding
{
  let current: TranscriptionAuthorization

  init(
    current: TranscriptionAuthorization = TranscriptionAuthorization(
      microphone: .authorized,
      speechRecognition: .authorized
    )
  ) {
    self.current = current
  }
}

private struct LocalAIFixedTargeter: FocusedTextTargeting {
  let supportsMultilineText: Bool
  let selectedRange: FocusedTextRange?

  init(
    supportsMultilineText: Bool = true,
    selectedRange: FocusedTextRange? = FocusedTextRange(
      location: 0,
      length: 0
    )
  ) {
    self.supportsMultilineText = supportsMultilineText
    self.selectedRange = selectedRange
  }

  func capture() throws -> FocusedTextTarget {
    FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      applicationName: "Notes",
      applicationBundleIdentifier: "com.apple.Notes",
      role: kAXTextAreaRole as String,
      supportsMultilineText: supportsMultilineText,
      selectedRange: selectedRange,
      deliveryCapability: .finalOnly
    )
  }

  func isStillFocused(_ target: FocusedTextTarget) -> Bool {
    true
  }
}

private struct LocalAIFixedContextCapturer: LocalAIContextCapturing {
  func capture(
    for target: FocusedTextTarget,
    profileName: String,
    locale: Locale,
    includeNearbyText: Bool
  ) -> LocalAITargetContext {
    LocalAITargetContext(
      localeIdentifier: locale.identifier,
      profileName: profileName,
      applicationName: target.applicationName,
      applicationBundleIdentifier: target.applicationBundleIdentifier,
      targetRole: target.role,
      supportsMultilineText: target.supportsMultilineText,
      nearbyText: nil
    )
  }
}

private final class LocalAIFakeRecognitionFactory:
  ContextualSpeechRecognitionSessionCreating,
  @unchecked Sendable
{
  let session: LocalAIFakeRecognitionSession
  private let lock = NSLock()
  private var hintStorage: [[String]] = []

  init(session: LocalAIFakeRecognitionSession) {
    self.session = session
  }

  var vocabularyHints: [[String]] {
    lock.withLock { hintStorage }
  }

  func makeSession(
    locale: Locale
  ) async throws -> any SpeechRecognitionSession {
    session
  }

  func makeSession(
    locale: Locale,
    vocabularyHints: [String]
  ) async throws -> any SpeechRecognitionSession {
    lock.withLock { hintStorage.append(vocabularyHints) }
    return session
  }
}

private final class LocalAIFakeRecognitionSession:
  SpeechRecognitionSession,
  @unchecked Sendable
{
  private let lock = NSLock()
  let updates: AsyncThrowingStream<TranscriptRevision, any Error>
  private let continuation: AsyncThrowingStream<TranscriptRevision, any Error>.Continuation
  private var appends = 0

  init() {
    (updates, continuation) = AsyncThrowingStream.makeStream()
  }

  func emit(_ revision: TranscriptRevision) {
    continuation.yield(revision)
  }

  var appendCount: Int {
    lock.withLock { appends }
  }

  func fail(_ error: any Error) {
    continuation.finish(throwing: error)
  }

  func append(_ audio: CapturedAudioBuffer) async throws {
    lock.withLock { appends += 1 }
  }

  func finish() async throws {
    continuation.finish()
  }

  func cancel() async {
    continuation.finish()
  }
}

private final class LocalAIFakeMicrophone:
  MicrophoneCapturing,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<CapturedAudioBuffer, any Error>.Continuation?
  private var starts = 0

  var startCount: Int {
    lock.withLock { starts }
  }

  func start() async throws
    -> AsyncThrowingStream<CapturedAudioBuffer, any Error>
  {
    lock.withLock { starts += 1 }
    let (stream, continuation) = AsyncThrowingStream<
      CapturedAudioBuffer,
      any Error
    >.makeStream()
    lock.withLock { self.continuation = continuation }
    return stream
  }

  func emit(_ audio: CapturedAudioBuffer) {
    _ = lock.withLock {
      continuation?.yield(audio)
    }
  }

  func stop() async {
    lock.withLock {
      continuation?.finish()
      continuation = nil
    }
  }
}

private final class LocalAIRecordingWriter:
  TranscriptWriting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let failure: TranscriptionFailure?
  private var storage: [String] = []

  init(failure: TranscriptionFailure? = nil) {
    self.failure = failure
  }

  var inserted: [String] {
    lock.withLock { storage }
  }

  func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) throws {
    if let failure {
      throw failure
    }
    lock.withLock { storage.append(text) }
  }
}

private actor LocalAIFakeRefinementRouter: LocalAIRefinementRouting {
  enum Behavior: Sendable {
    case output(String)
    case delayedOutput(String, Duration)
    case nonCooperativeDelayedOutput(String, Duration)
    case failure(LocalAIRefinementFailure)
  }

  let behavior: Behavior
  let preparationDelay: Duration?
  private(set) var wasPreparationCancelled = false
  private var preparationCancellationObservers: [CheckedContinuation<Void, Never>] = []
  private(set) var preparationCount = 0
  private(set) var refinementCompletionCount = 0
  private(set) var requests: [LocalAIRefinementRequest] = []
  private(set) var releasedSettings: [LocalAISettings] = []
  private(set) var shutdownCount = 0

  init(
    behavior: Behavior,
    preparationDelay: Duration?
  ) {
    self.behavior = behavior
    self.preparationDelay = preparationDelay
  }

  func readiness(
    settings: LocalAISettings,
    locale: Locale
  ) -> LocalAIReadinessSnapshot {
    LocalAIReadinessSnapshot(
      apple: LocalAIProviderReadiness(
        provider: .appleOnDevice,
        state: .ready
      ),
      ollama: LocalAIProviderReadiness(
        provider: .ollama,
        state: .ready
      )
    )
  }

  func prepare(settings: LocalAISettings) async throws {
    preparationCount += 1
    guard let preparationDelay else {
      return
    }
    do {
      try await Task.sleep(for: preparationDelay)
    } catch is CancellationError {
      wasPreparationCancelled = true
      let observers = preparationCancellationObservers
      preparationCancellationObservers.removeAll()
      for observer in observers {
        observer.resume()
      }
      throw CancellationError()
    }
  }

  func waitUntilPreparationCancelled() async {
    await withCheckedContinuation { observer in
      guard !wasPreparationCancelled else {
        observer.resume()
        return
      }
      preparationCancellationObservers.append(observer)
    }
  }

  func refine(
    _ request: LocalAIRefinementRequest,
    settings: LocalAISettings
  ) async throws -> LocalAIRefinementResponse {
    requests.append(request)
    let output: String
    switch behavior {
    case .output(let value):
      output = value
    case .delayedOutput(let value, let delay):
      try await Task.sleep(for: delay)
      output = value
    case .nonCooperativeDelayedOutput(let value, let delay):
      await Task.detached {
        try? await Task.sleep(for: delay)
      }.value
      output = value
    case .failure(let failure):
      throw failure
    }
    refinementCompletionCount += 1
    return LocalAIRefinementResponse(
      text: output,
      provider: settings.provider,
      modelIdentifier: "test-model"
    )
  }

  func release(settings: LocalAISettings) {
    releasedSettings.append(settings)
  }

  func shutdown() {
    shutdownCount += 1
  }
}

private actor RemoteCapableRefinerProbe: TranscriptRefining {
  nonisolated let capability = LocalAIProviderCapability(
    provider: .ollama,
    locality: .remoteCapable
  )
  private(set) var invocationCount = 0

  func readiness(
    settings: LocalAISettings,
    locale: Locale
  ) -> LocalAIProviderReadiness {
    invocationCount += 1
    return LocalAIProviderReadiness(
      provider: .ollama,
      state: .ready
    )
  }

  func prepare(settings: LocalAISettings) {
    invocationCount += 1
  }

  func refine(
    _ request: LocalAIRefinementRequest,
    settings: LocalAISettings
  ) -> LocalAIRefinementResponse {
    invocationCount += 1
    return LocalAIRefinementResponse(
      text: request.transcript,
      provider: .ollama,
      modelIdentifier: "remote-probe"
    )
  }

  func release(settings: LocalAISettings) {
    invocationCount += 1
  }

  func shutdown() {
    invocationCount += 1
  }
}

private func localAIWaitUntil(
  timeout: Duration = .seconds(5),
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() {
      return
    }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Timed out waiting for Local AI Dictation state.")
}
