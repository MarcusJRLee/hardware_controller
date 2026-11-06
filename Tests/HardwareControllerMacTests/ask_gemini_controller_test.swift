import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct AskGeminiControllerTest {
  @Test
  func presentsTheFinalQuestionOnceWithoutTouchingTheFocusedApp() async throws {
    let fixture = AskGeminiFixture()

    await fixture.controller.handle(.begin)
    try await waitUntil { fixture.microphone.isCapturing }
    fixture.session.emit(
      TranscriptRevision(committedText: "  what is a roguelike ", provisionalText: ""))
    await fixture.controller.handle(.finish)
    try await waitUntil { await fixture.presenter.questions == ["what is a roguelike"] }

    let snapshots = fixture.snapshots.values
    #expect(snapshots.contains { $0.phase == .listening && $0.targetApplicationName == "Gemini" })
    #expect(snapshots.last?.phase == .completed)
    await fixture.controller.shutdown()
    #expect(await fixture.presenter.questions == ["what is a roguelike"])
  }

  @Test
  func silenceAndMissingPermissionPresentNothing() async throws {
    let silent = AskGeminiFixture()
    await silent.controller.handle(.begin)
    try await waitUntil { silent.microphone.isCapturing }
    await silent.controller.handle(.finish)
    try await waitUntil { silent.snapshots.values.last?.phase == .completed }

    let denied = AskGeminiFixture(microphone: .denied)
    await denied.controller.handle(.begin)
    try await waitUntil { denied.snapshots.values.last?.phase == .failed }

    #expect(await silent.presenter.questions.isEmpty)
    #expect(await denied.presenter.questions.isEmpty)
    #expect(denied.snapshots.values.last?.failure == .microphonePermissionDenied)
  }
}

private final class AskGeminiFixture: Sendable {
  let session = AskGeminiFakeSession()
  let microphone = AskGeminiFakeMicrophone()
  let presenter = RecordingPresenter()
  let snapshots = AskGeminiSnapshots()
  let controller: AskGeminiController

  init(microphone permission: PermissionStatus = .authorized) {
    let snapshots = snapshots
    controller = AskGeminiController(
      factory: AskGeminiFakeFactory(session: session),
      microphone: microphone,
      authorization: AskGeminiAuthorization(
        current: TranscriptionAuthorization(microphone: permission, speechRecognition: .authorized)
      ),
      presenter: presenter,
      snapshotHandler: { snapshots.append($0) }
    )
  }
}

private actor RecordingPresenter: AskGeminiPresenting {
  private(set) var questions: [String] = []

  func present(question: String) {
    questions.append(question)
  }
}

private final class AskGeminiSnapshots: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [TranscriptionSnapshot] = []

  var values: [TranscriptionSnapshot] { lock.withLock { stored } }

  func append(_ snapshot: TranscriptionSnapshot) {
    lock.withLock { stored.append(snapshot) }
  }
}

private struct AskGeminiAuthorization: TranscriptionAuthorizationProviding {
  let current: TranscriptionAuthorization
}

private struct AskGeminiFakeFactory: SpeechRecognitionSessionCreating {
  let session: AskGeminiFakeSession

  func makeSession(locale: Locale) async throws -> any SpeechRecognitionSession {
    session
  }
}

private final class AskGeminiFakeSession: SpeechRecognitionSession, @unchecked Sendable {
  let updates: AsyncThrowingStream<TranscriptRevision, any Error>
  private let continuation: AsyncThrowingStream<TranscriptRevision, any Error>.Continuation

  init() {
    (updates, continuation) = AsyncThrowingStream.makeStream()
  }

  func emit(_ revision: TranscriptRevision) { continuation.yield(revision) }
  func append(_ audio: CapturedAudioBuffer) async throws {}
  func finish() async throws { continuation.finish() }
  func cancel() async { continuation.finish() }
}

private final class AskGeminiFakeMicrophone: MicrophoneCapturing, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<CapturedAudioBuffer, any Error>.Continuation?

  var isCapturing: Bool { lock.withLock { continuation != nil } }

  func start() async throws -> AsyncThrowingStream<CapturedAudioBuffer, any Error> {
    let (stream, continuation) = AsyncThrowingStream<CapturedAudioBuffer, any Error>.makeStream()
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

private func waitUntil(
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
  Issue.record("Timed out waiting for Ask Gemini state.")
}
