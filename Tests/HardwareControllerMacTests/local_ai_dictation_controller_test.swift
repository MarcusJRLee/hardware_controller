@preconcurrency import ApplicationServices
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct LocalAIDictationControllerTest {
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
  func providerTestBoundsPreparationAndGenerationTogether() async {
    let fixture = LocalAIControllerFixture(
      refinement: .output("Unused."),
      preparationDelay: .seconds(1)
    )
    let controller = fixture.makeController(
      refinementTimeout: .milliseconds(20)
    )
    let clock = ContinuousClock()
    let start = clock.now

    let failure = await controller.testProvider()

    #expect(failure == .timedOut)
    #expect(start.duration(to: clock.now) < .milliseconds(200))
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

  @Test
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
    #expect(snapshot.refinedText.isEmpty)
    #expect(
      snapshot.fallbackReason
        == .providerUnavailable("Ollama is not running.")
    )
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
    #expect(await controller.snapshot().refinedText.isEmpty)
    #expect(await controller.snapshot().fallbackReason == .timedOut)
  }

  @Test
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
  let writer = LocalAIRecordingWriter()
  let factory: LocalAIFakeRecognitionFactory
  let refiner: LocalAIFakeRefinementRouter

  init(
    refinement: LocalAIFakeRefinementRouter.Behavior,
    preparationDelay: Duration? = nil
  ) {
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
      LocalAIFixedAuthorization()
  ) -> LocalAIDictationController {
    LocalAIDictationController(
      factory: factory,
      microphone: microphone,
      targeter: LocalAIFixedTargeter(),
      writer: writer,
      authorization: authorization,
      contextCapturer: LocalAIFixedContextCapturer(),
      refiner: refiner ?? self.refiner,
      settings: settings,
      profileName: "Coding",
      refinementTimeout: refinementTimeout
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
  func capture() throws -> FocusedTextTarget {
    FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      applicationName: "Notes",
      applicationBundleIdentifier: "com.apple.Notes",
      role: kAXTextAreaRole as String,
      supportsMultilineText: true,
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
  let updates: AsyncThrowingStream<TranscriptRevision, any Error>
  private let continuation: AsyncThrowingStream<TranscriptRevision, any Error>.Continuation

  init() {
    (updates, continuation) = AsyncThrowingStream.makeStream()
  }

  func emit(_ revision: TranscriptRevision) {
    continuation.yield(revision)
  }

  func append(_ audio: CapturedAudioBuffer) async throws {}

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
  private var storage: [String] = []

  var inserted: [String] {
    lock.withLock { storage }
  }

  func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) throws {
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
  private(set) var preparationCount = 0
  private(set) var refinementCompletionCount = 0
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
      throw CancellationError()
    }
  }

  func refine(
    _ request: LocalAIRefinementRequest,
    settings: LocalAISettings
  ) async throws -> LocalAIRefinementResponse {
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

private func localAIWaitUntil(
  timeout: Duration = .seconds(1),
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
