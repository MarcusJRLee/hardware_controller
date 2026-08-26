import AVFoundation
@preconcurrency import ApplicationServices
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct OwnedTranscriptionControllerTest {
  @Test
  func forwardsCapturedAudioWithoutChangingRecognitionOwnership()
    async throws
  {
    let fixture = Fixture()
    let audioRecorder = AudioBufferRecorder()
    let controller = fixture.makeController(
      audioBufferHandler: audioRecorder.append
    )

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.microphone.emit(try makeVoiceAudioFixture())

    try await waitUntil {
      audioRecorder.count == 1
    }
    await controller.handle(.cancel)
  }

  @Test
  func pressStreamsSpeechAndReleaseCompletes() async throws {
    let fixture = Fixture()
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.session.emit(.provisional("hello"))
    fixture.session.emit(.committed("Hello"))
    try await waitUntil {
      fixture.writer.inserted == ["Hello"]
    }

    await controller.handle(.finish)
    try await waitUntil {
      await controller.snapshot().phase == .completed
    }

    let snapshot = await controller.snapshot()
    #expect(snapshot.finalText == "Hello")
    #expect(snapshot.targetApplicationName == "Notes")
    #expect(
      fixture.snapshots.phases == [
        .preparing,
        .listening,
        .listening,
        .listening,
        .finalizing,
        .completed,
      ]
    )
  }

  @Test
  func rapidReleaseFinalizesWithoutStartingVisualListening()
    async throws
  {
    let fixture = Fixture(preparationDelay: .milliseconds(50))
    let controller = fixture.makeController()

    await controller.handle(.begin)
    await controller.handle(.finish)

    try await waitUntil {
      await controller.snapshot().phase == .completed
    }
    #expect(!fixture.snapshots.phases.contains(.listening))
    #expect(
      fixture.snapshots.phases == [
        .preparing,
        .finalizing,
        .completed,
      ]
    )
  }

  @Test
  func changedFocusFailsAndKeepsRecognizedText()
    async throws
  {
    let fixture = Fixture(
      writerFailure: .focusChanged
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.session.emit(.committed("Keep this text"))

    try await waitUntil {
      await controller.snapshot().phase == .failed
    }
    let snapshot = await controller.snapshot()
    #expect(snapshot.failure == .focusChanged)
    #expect(snapshot.finalText == "Keep this text")
    #expect(snapshot.hasRecoverableTranscript)
  }

  @Test
  func compatibleTargetReceivesLiveRevisionsInPlace()
    async throws
  {
    let anchor = FocusedTextRange(
      location: 12,
      length: 0
    )
    let fixture = Fixture(
      deliveryCapability:
        .liveComposition(anchor: anchor)
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.session.emit(.provisional("hard ware"))
    try await waitUntil {
      fixture.writer.replacements.count == 1
    }
    fixture.session.emit(
      .provisional("hardware controller")
    )
    try await waitUntil {
      fixture.writer.replacements.count == 2
    }
    fixture.session.emit(
      .committed("Hardware Controller")
    )
    try await waitUntil {
      fixture.writer.replacements.count == 3
    }

    #expect(fixture.writer.inserted.isEmpty)
    #expect(
      fixture.writer.replacements.map(\.replacementText)
        == [
          "hard ware",
          "hardware controller",
          "Hardware Controller",
        ]
    )
    #expect(
      fixture.writer.anchors == [anchor, anchor, anchor]
    )
  }

  @Test
  func bufferedTargetWaitsForFinalization()
    async throws
  {
    let fixture = Fixture(
      deliveryCapability:
        .bufferedEvent(
          anchor: FocusedTextRange(
            location: 8,
            length: 0
          ),
          destination: .focusedForeground
        )
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.session.emit(.committed("echo hardware"))
    try await waitUntil {
      await controller.snapshot().finalText == "echo hardware"
    }
    #expect(fixture.writer.inserted.isEmpty)
    #expect(
      await controller.snapshot().phase == .listening
    )

    await controller.handle(.finish)
    try await waitUntil {
      await controller.snapshot().phase == .completed
    }

    #expect(fixture.writer.inserted == ["echo hardware"])
  }

  /// Proves cancellation cannot deliver buffered text.
  @Test
  func cancelingBufferedTargetNeverInserts() async throws {
    let fixture = Fixture(
      deliveryCapability:
        .bufferedEvent(
          anchor: FocusedTextRange(location: 0, length: 0),
          destination: .focusedForeground
        )
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.session.emit(.committed("do not insert"))
    try await waitUntil {
      await controller.snapshot().finalText == "do not insert"
    }

    await controller.handle(.cancel)

    #expect(await controller.snapshot().phase == .idle)
    #expect(fixture.writer.inserted.isEmpty)
  }

  /// Retains recoverable text when final buffered delivery fails.
  @Test
  func failedBufferedDeliveryKeepsRecoverableText()
    async throws
  {
    let fixture = Fixture(
      writerFailure: .insertionFailed,
      deliveryCapability:
        .bufferedEvent(
          anchor: FocusedTextRange(location: 0, length: 0),
          destination: .focusedForeground
        )
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.session.emit(.committed("recover this"))
    try await waitUntil {
      await controller.snapshot().finalText == "recover this"
    }

    await controller.handle(.finish)
    try await waitUntil {
      await controller.snapshot().phase == .failed
    }

    let snapshot = await controller.snapshot()
    #expect(snapshot.failure == .insertionFailed)
    #expect(snapshot.finalText == "recover this")
    #expect(snapshot.hasRecoverableTranscript)
    #expect(fixture.writer.inserted.isEmpty)
  }

  /// Converts an unexpected backend cancellation into a recoverable failure.
  @Test
  func unexpectedFinalizationCancellationFails() async throws {
    let fixture = Fixture(
      finishBehavior: .throwCancellation
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.session.emit(.committed("recover this"))
    try await waitUntil {
      await controller.snapshot().finalText == "recover this"
    }

    await controller.handle(.finish)
    try await waitUntil {
      await controller.snapshot().phase == .failed
    }

    let snapshot = await controller.snapshot()
    #expect(
      snapshot.failure
        == .recognitionFailed(
          "On-device recognition did not finish."
        )
    )
    #expect(snapshot.finalText == "recover this")
  }

  /// Fails when an active result stream throws cancellation independently.
  @Test
  func unexpectedUpdateCancellationFails() async throws {
    let fixture = Fixture()
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.session.failUpdates(with: CancellationError())

    try await waitUntil {
      await controller.snapshot().phase == .failed
    }

    #expect(
      await controller.snapshot().failure
        == .recognitionFailed(
          "On-device recognition did not finish."
        )
    )
    #expect(fixture.session.cancelCount == 1)
  }

  /// Rejects buffered delivery when updates cancel during finalization.
  @Test
  func updateCancellationDuringFinalizationFailsWithoutDelivery()
    async throws
  {
    let fixture = Fixture(
      deliveryCapability:
        .bufferedEvent(
          anchor: FocusedTextRange(location: 0, length: 0),
          destination: .focusedForeground
        ),
      finishBehavior: .cancelUpdates
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.session.emit(.committed("recover this"))
    try await waitUntil {
      await controller.snapshot().finalText == "recover this"
    }

    await controller.handle(.finish)
    try await waitUntil {
      await controller.snapshot().phase == .failed
    }

    let snapshot = await controller.snapshot()
    #expect(
      snapshot.failure
        == .recognitionFailed(
          "On-device recognition did not finish."
        )
    )
    #expect(snapshot.hasRecoverableTranscript)
    #expect(fixture.writer.inserted.isEmpty)
  }

  /// Fails when results end normally before finalization begins.
  @Test
  func earlyUpdateCompletionFails() async throws {
    let fixture = Fixture()
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.session.endUpdates()

    try await waitUntil {
      await controller.snapshot().phase == .failed
    }

    #expect(
      await controller.snapshot().failure
        == .recognitionFailed(
          "On-device recognition did not finish."
        )
    )
  }

  /// Fails when microphone delivery is canceled without controller intent.
  @Test
  func unexpectedAudioCancellationFails() async throws {
    let fixture = Fixture()
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.microphone.fail(with: CancellationError())

    try await waitUntil {
      await controller.snapshot().phase == .failed
    }

    #expect(
      await controller.snapshot().failure
        == .recognitionFailed(
          "On-device recognition did not finish."
        )
    )
  }

  /// Maps an input switch to a recoverable failure and completes cleanup.
  @Test
  func inputConfigurationChangeFailsWithoutCrashing() async throws {
    let fixture = Fixture()
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.microphone.fail(
      with: MicrophoneCaptureError.inputConfigurationChanged
    )

    try await waitUntil {
      fixture.microphone.stopCount == 1
    }

    #expect(
      await controller.snapshot().failure
        == .audioUnavailable(
          "The microphone input changed. Try Dictation again."
        )
    )
  }

  /// Fails when microphone delivery ends before finalization stops it.
  @Test
  func earlyAudioCompletionFails() async throws {
    let fixture = Fixture()
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.microphone.endAudio()

    try await waitUntil {
      await controller.snapshot().phase == .failed
    }

    #expect(
      await controller.snapshot().failure
        == .audioUnavailable(
          "Microphone audio stopped unexpectedly."
        )
    )
  }

  /// Fails when session creation throws cancellation while still active.
  @Test
  func unexpectedPreparationCancellationFails() async throws {
    let fixture = Fixture(sessionCreationCancels: true)
    let controller = fixture.makeController()

    await controller.handle(.begin)

    try await waitUntil {
      await controller.snapshot().phase == .failed
    }

    #expect(
      await controller.snapshot().failure
        == .recognitionFailed(
          "On-device recognition did not finish."
        )
    )
  }

  /// Bounds an unresponsive backend and retains committed text for recovery.
  @Test
  func finalizationTimeoutFailsAndCancelsBackend()
    async throws
  {
    let fixture = Fixture(
      finishBehavior: .waitForCancellation,
      finalizationTimeout: .milliseconds(20),
      cancellationDelay: .milliseconds(200)
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.session.emit(.committed("recover this"))
    try await waitUntil {
      await controller.snapshot().finalText == "recover this"
    }

    await controller.handle(.finish)
    try await waitUntil {
      fixture.snapshots.phases.last == .failed
    }
    #expect(fixture.session.cancelFinishedCount == 0)
    try await waitUntil {
      fixture.session.cancelFinishedCount == 1
    }

    let snapshot = await controller.snapshot()
    #expect(
      snapshot.failure
        == .recognitionFailed(
          "On-device recognition did not finish."
        )
    )
    #expect(snapshot.finalText == "recover this")
    #expect(fixture.session.cancelCount == 1)
  }

  /// Allows explicit cancellation to interrupt in-progress finalization.
  @Test
  func cancelDuringFinalizationReturnsToIdle() async throws {
    let fixture = Fixture(
      finishBehavior: .waitForCancellation
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    await controller.handle(.finish)
    await controller.handle(.cancel)

    #expect(await controller.snapshot().phase == .idle)
    #expect(fixture.session.cancelCount == 1)
  }

  /// Prevents a completed session's deadline from changing its final state.
  @Test
  func completedFinalizationCancelsTimeout() async throws {
    let fixture = Fixture(
      finalizationTimeout: .milliseconds(20)
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    await controller.handle(.finish)
    try await waitUntil {
      await controller.snapshot().phase == .completed
    }
    try await Task.sleep(for: .milliseconds(40))

    #expect(await controller.snapshot().phase == .completed)
    #expect(fixture.session.cancelCount == 0)
  }

  @Test
  func cancelRemovesOwnedProvisionalText() async throws {
    let fixture = Fixture(
      deliveryCapability:
        .liveComposition(
          anchor: FocusedTextRange(
            location: 4,
            length: 0
          )
        )
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)
    try await waitUntil {
      await controller.snapshot().phase == .listening
    }
    fixture.session.emit(.provisional("temporary"))
    try await waitUntil {
      fixture.writer.replacements.count == 1
    }

    await controller.handle(.cancel)

    #expect(
      fixture.writer.replacements.last?
        .replacementText == ""
    )
    #expect(
      await controller.snapshot().phase == .idle
    )
  }

  @Test
  func permissionFailureNeverStartsTheMicrophone()
    async
  {
    let fixture = Fixture(
      authorization: TranscriptionAuthorization(
        microphone: .denied,
        speechRecognition: .authorized
      )
    )
    let controller = fixture.makeController()

    await controller.handle(.begin)

    let snapshot = await controller.snapshot()
    #expect(snapshot.phase == .failed)
    #expect(
      snapshot.failure == .microphonePermissionDenied
    )
    #expect(fixture.microphone.startCount == 0)
  }

  /// Rejects Dictation before audio starts when no editable target is focused.
  @Test
  func missingFocusedTargetNeverStartsTheMicrophone() async {
    let fixture = Fixture(targetFailure: .noFocusedTextField)
    let controller = fixture.makeController()

    await controller.handle(.begin)

    let snapshot = await controller.snapshot()
    #expect(snapshot.phase == .failed)
    #expect(snapshot.failure == .noFocusedTextField)
    #expect(fixture.microphone.startCount == 0)
  }

  @Test
  func cancelDuringPreparationReturnsToIdle() async throws {
    let fixture = Fixture(preparationDelay: .milliseconds(100))
    let controller = fixture.makeController()

    await controller.handle(.begin)
    await controller.handle(.cancel)

    try await waitUntil {
      await controller.snapshot().phase == .idle
    }
    #expect(
      fixture.snapshots.phases == [
        .preparing,
        .canceling,
        .idle,
      ]
    )
  }

  @Test
  func warmUpPreparesRecognitionWithoutStartingAudio()
    async
  {
    let fixture = Fixture()
    let controller = fixture.makeController()

    let failure = await controller.warmUp()

    #expect(failure == nil)
    #expect(fixture.factory.prepareCount == 1)
    #expect(fixture.microphone.prepareCount == 1)
    #expect(fixture.microphone.startCount == 0)
  }

  @Test
  func shutdownReleasesThePreparedRecognitionFactory()
    async
  {
    let fixture = Fixture()
    let controller = fixture.makeController()

    _ = await controller.warmUp()
    await controller.shutdown()

    #expect(fixture.factory.shutdownCount == 1)
  }

  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_RUN_PIPELINE_INTEGRATION"
        ] == "1"
    )
  )
  @available(macOS 26, *)
  func localAudioFlowsThroughControllerIntoRealField()
    async throws
  {
    let path = try #require(
      ProcessInfo.processInfo.environment[
        "HC_SPEECH_AUDIO_FILE"
      ]
    )
    let microphone = AudioFileMicrophone(
      url: URL(fileURLWithPath: path)
    )
    let targeter = AccessibilityFocusedTextTargeting()
    let target = try targeter.capture()
    guard
      case .liveComposition =
        target.deliveryCapability
    else {
      Issue.record(
        "The integration field did not expose a stable editable text range."
      )
      return
    }
    let controller = OwnedTranscriptionController(
      factory: AppleSpeechRecognitionSessionFactory(),
      microphone: microphone,
      targeter: targeter,
      writer: SafeTranscriptWriter(
        targeter: targeter,
        inserter: AccessibilitySelectedTextInserter()
      ),
      authorization: FixedAuthorization(
        current: TranscriptionAuthorization(
          microphone: .authorized,
          speechRecognition: .authorized
        )
      ),
      locale: Locale(identifier: "en-US")
    )

    await controller.handle(.begin)
    try await waitUntil(timeout: .seconds(3)) {
      await controller.snapshot().phase == .listening
    }
    try await waitUntil(timeout: .seconds(3)) {
      await microphone.didFinishFeeding
    }
    await controller.handle(.finish)
    try await waitUntil(timeout: .seconds(3)) {
      await controller.snapshot().phase == .completed
    }

    let snapshot = await controller.snapshot()
    #expect(
      snapshot.finalText.lowercased()
        .contains("hardware controller")
    )
    var value: CFTypeRef?
    #expect(
      AXUIElementCopyAttributeValue(
        target.element,
        kAXValueAttribute as CFString,
        &value
      ) == .success
    )
    #expect(
      (value as? String)?.lowercased()
        .contains("hardware controller") == true
    )
    await controller.shutdown()
  }
}

private final class Fixture: @unchecked Sendable {
  let session: FakeRecognitionSession
  let microphone = FakeMicrophone()
  let writer: FakeTranscriptWriter
  let snapshots = SnapshotRecorder()
  let factory: FakeRecognitionFactory
  private let authorization: FixedAuthorization
  private let deliveryCapability: FocusedTextDeliveryCapability
  private let finalizationTimeout: Duration
  private let targetFailure: TranscriptionFailure?

  init(
    preparationDelay: Duration = .zero,
    writerFailure: TranscriptionFailure? = nil,
    deliveryCapability:
      FocusedTextDeliveryCapability = .finalOnly,
    finishBehavior: FakeFinishBehavior = .complete,
    finalizationTimeout: Duration = .seconds(5),
    cancellationDelay: Duration = .zero,
    sessionCreationCancels: Bool = false,
    targetFailure: TranscriptionFailure? = nil,
    authorization: TranscriptionAuthorization =
      TranscriptionAuthorization(
        microphone: .authorized,
        speechRecognition: .authorized
      )
  ) {
    writer = FakeTranscriptWriter(failure: writerFailure)
    self.authorization = FixedAuthorization(
      current: authorization
    )
    self.deliveryCapability = deliveryCapability
    self.finalizationTimeout = finalizationTimeout
    self.targetFailure = targetFailure
    session = FakeRecognitionSession(
      finishBehavior: finishBehavior,
      cancellationDelay: cancellationDelay
    )
    factory = FakeRecognitionFactory(
      session: session,
      delay: preparationDelay,
      sessionCreationCancels: sessionCreationCancels
    )
  }

  func makeController(
    audioBufferHandler:
      @escaping @Sendable (CapturedAudioBuffer) -> Void = { _ in }
  ) -> OwnedTranscriptionController {
    OwnedTranscriptionController(
      factory: factory,
      microphone: microphone,
      targeter: FixedTargeter(
        deliveryCapability: deliveryCapability,
        failure: targetFailure
      ),
      writer: writer,
      authorization: authorization,
      finalizationTimeout: finalizationTimeout,
      audioBufferHandler: audioBufferHandler,
      snapshotHandler: { [snapshots] snapshot in
        snapshots.append(snapshot)
      }
    )
  }
}

private struct FixedAuthorization:
  TranscriptionAuthorizationProviding
{
  let current: TranscriptionAuthorization
}

private struct FixedTargeter: FocusedTextTargeting {
  let deliveryCapability: FocusedTextDeliveryCapability
  let failure: TranscriptionFailure?

  func capture() throws -> FocusedTextTarget {
    if let failure {
      throw failure
    }
    return FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      applicationName: "Notes",
      deliveryCapability: deliveryCapability
    )
  }

  func isStillFocused(
    _ target: FocusedTextTarget
  ) -> Bool {
    true
  }
}

private final class FakeRecognitionFactory:
  SpeechRecognitionSessionCreating,
  @unchecked Sendable
{
  let session: FakeRecognitionSession
  let delay: Duration
  private let sessionCreationCancels: Bool
  private let lock = NSLock()
  private var prepares = 0
  private var shutdowns = 0

  var prepareCount: Int {
    lock.withLock { prepares }
  }

  var shutdownCount: Int {
    lock.withLock { shutdowns }
  }

  init(
    session: FakeRecognitionSession,
    delay: Duration,
    sessionCreationCancels: Bool
  ) {
    self.session = session
    self.delay = delay
    self.sessionCreationCancels = sessionCreationCancels
  }

  func prepare(locale: Locale) async throws {
    lock.withLock {
      prepares += 1
    }
  }

  func makeSession(
    locale: Locale
  ) async throws -> any SpeechRecognitionSession {
    try await Task.sleep(for: delay)
    if sessionCreationCancels {
      throw CancellationError()
    }
    return session
  }

  func shutdown() async {
    lock.withLock {
      shutdowns += 1
    }
  }
}

private enum FakeFinishBehavior: Sendable {
  case complete
  case cancelUpdates
  case throwCancellation
  case waitForCancellation
}

private final class FakeRecognitionSession:
  SpeechRecognitionSession,
  @unchecked Sendable
{
  let updates:
    AsyncThrowingStream<
      TranscriptRevision,
      any Error
    >
  private let continuation:
    AsyncThrowingStream<
      TranscriptRevision,
      any Error
    >.Continuation
  private let finishBehavior: FakeFinishBehavior
  private let cancellationStream: AsyncStream<Void>
  private let cancellationContinuation: AsyncStream<Void>.Continuation
  private let cancellationDelay: Duration
  private let lock = NSLock()
  private var cancellations = 0
  private var finishedCancellations = 0

  var cancelCount: Int {
    lock.withLock { cancellations }
  }

  var cancelFinishedCount: Int {
    lock.withLock { finishedCancellations }
  }

  /// Creates a controllable finalization boundary.
  init(
    finishBehavior: FakeFinishBehavior = .complete,
    cancellationDelay: Duration = .zero
  ) {
    self.finishBehavior = finishBehavior
    self.cancellationDelay = cancellationDelay
    (updates, continuation) =
      AsyncThrowingStream.makeStream()
    (cancellationStream, cancellationContinuation) =
      AsyncStream.makeStream()
  }

  func emit(_ update: TranscriptRevision) {
    continuation.yield(update)
  }

  /// Terminates result delivery with a controlled failure.
  func failUpdates(with error: any Error) {
    continuation.finish(throwing: error)
  }

  /// Terminates result delivery before finalization requests it.
  func endUpdates() {
    continuation.finish()
  }

  func append(_ audio: CapturedAudioBuffer) async throws {}

  /// Applies the configured finalization outcome.
  func finish() async throws {
    switch finishBehavior {
    case .complete:
      continuation.finish()
    case .cancelUpdates:
      continuation.finish(throwing: CancellationError())
    case .throwCancellation:
      throw CancellationError()
    case .waitForCancellation:
      for await _ in cancellationStream {
        break
      }
      throw CancellationError()
    }
  }

  /// Releases a waiting finalizer and records cancellation.
  func cancel() async {
    lock.withLock {
      cancellations += 1
    }
    try? await Task.sleep(for: cancellationDelay)
    cancellationContinuation.yield()
    cancellationContinuation.finish()
    continuation.finish()
    lock.withLock {
      finishedCancellations += 1
    }
  }
}

private final class FakeMicrophone:
  MicrophoneCapturing,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var preparations = 0
  private var starts = 0
  private var stops = 0
  private var continuation:
    AsyncThrowingStream<
      CapturedAudioBuffer,
      any Error
    >.Continuation?

  var prepareCount: Int {
    lock.withLock { preparations }
  }

  var startCount: Int {
    lock.withLock { starts }
  }

  var stopCount: Int {
    lock.withLock { stops }
  }

  func prepare() async throws {
    lock.withLock {
      preparations += 1
    }
  }

  func start() async throws
    -> AsyncThrowingStream<CapturedAudioBuffer, any Error>
  {
    lock.withLock {
      starts += 1
    }
    let (stream, continuation) =
      AsyncThrowingStream<
        CapturedAudioBuffer,
        any Error
      >.makeStream()
    lock.withLock {
      self.continuation = continuation
    }
    return stream
  }

  func stop() async {
    lock.withLock {
      stops += 1
      continuation?.finish()
      continuation = nil
    }
  }

  func emit(_ audio: CapturedAudioBuffer) {
    _ = lock.withLock {
      continuation?.yield(audio)
    }
  }

  /// Terminates microphone delivery with a controlled failure.
  func fail(with error: any Error) {
    lock.withLock {
      continuation?.finish(throwing: error)
      continuation = nil
    }
  }

  /// Terminates microphone delivery before finalization requests it.
  func endAudio() {
    lock.withLock {
      continuation?.finish()
      continuation = nil
    }
  }
}

private final class AudioBufferRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var count: Int {
    lock.withLock { storage }
  }

  func append(_ audio: CapturedAudioBuffer) {
    lock.withLock { storage += 1 }
  }
}

private actor AudioFileMicrophone: MicrophoneCapturing {
  private let url: URL
  private var continuation:
    AsyncThrowingStream<
      CapturedAudioBuffer,
      any Error
    >.Continuation?
  private var producer: Task<Void, Never>?
  private(set) var didFinishFeeding = false

  init(url: URL) {
    self.url = url
  }

  func start() async throws
    -> AsyncThrowingStream<CapturedAudioBuffer, any Error>
  {
    let (stream, continuation) =
      AsyncThrowingStream<
        CapturedAudioBuffer,
        any Error
      >.makeStream()
    self.continuation = continuation
    producer = Task {
      await feed(continuation)
    }
    return stream
  }

  func stop() async {
    continuation?.finish()
    continuation = nil
    producer?.cancel()
    producer = nil
  }

  private func feed(
    _ continuation:
      AsyncThrowingStream<
        CapturedAudioBuffer,
        any Error
      >.Continuation
  ) async {
    do {
      let file = try AVAudioFile(forReading: url)
      while file.framePosition < file.length {
        try Task.checkCancellation()
        let remaining = file.length - file.framePosition
        let capacity = AVAudioFrameCount(
          min(4_096, remaining)
        )
        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: capacity
          )
        else {
          throw MicrophoneCaptureError.noInputDevice
        }
        try file.read(
          into: buffer,
          frameCount: capacity
        )
        continuation.yield(
          try CapturedAudioBuffer(copying: buffer)
        )
        await Task.yield()
      }
      didFinishFeeding = true
    } catch is CancellationError {
      return
    } catch {
      continuation.finish(throwing: error)
    }
  }
}

private final class FakeTranscriptWriter:
  TranscriptWriting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let failure: TranscriptionFailure?
  private var storage: [String] = []
  private var replacementStorage: [TranscriptCompositionMutation] = []
  private var anchorStorage: [FocusedTextRange] = []

  init(failure: TranscriptionFailure?) {
    self.failure = failure
  }

  var inserted: [String] {
    lock.withLock { storage }
  }

  var replacements: [TranscriptCompositionMutation] {
    lock.withLock { replacementStorage }
  }

  var anchors: [FocusedTextRange] {
    lock.withLock { anchorStorage }
  }

  func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) throws {
    if let failure {
      throw failure
    }
    lock.withLock {
      storage.append(text)
    }
  }

  func replace(
    _ mutation: TranscriptCompositionMutation,
    anchoredAt anchor: FocusedTextRange,
    in target: FocusedTextTarget
  ) throws {
    if let failure {
      throw failure
    }
    lock.withLock {
      replacementStorage.append(mutation)
      anchorStorage.append(anchor)
    }
  }
}

private final class SnapshotRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [TranscriptionSnapshot] = []

  var phases: [TranscriptionPhase] {
    lock.withLock {
      storage.map(\.phase)
    }
  }

  func append(_ snapshot: TranscriptionSnapshot) {
    lock.withLock {
      storage.append(snapshot)
    }
  }
}

private func waitUntil(
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
  Issue.record("Timed out waiting for asynchronous state.")
}
