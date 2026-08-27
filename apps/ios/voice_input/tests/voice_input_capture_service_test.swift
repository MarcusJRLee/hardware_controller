import Foundation
import Synchronization
import VoiceInputShared
import XCTest

@testable import VoiceInput

final class VoiceInputCaptureServiceTest: XCTestCase {
  func testStaleStartCommandIsConsumedWithoutStartingCapture() async throws {
    let store = LockedProbeStore(
      command: .start(
        sessionID: UUID(),
        issuedAt: Date(timeIntervalSinceNow: -60)
      )
    )
    let captureURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).caf")
    let service = VoiceInputCaptureService(store: store, captureURL: captureURL)

    try await service.processPendingCommand()

    XCTAssertNil(try store.readCommand())
    XCTAssertEqual(try store.readSnapshot(), .idle(sequence: 0))
    XCTAssertFalse(FileManager.default.fileExists(atPath: captureURL.path))
  }

  func testStartReservesCaptureOwnershipWhileTheModelPrewarms() async throws {
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let provider = BlockingASRModelProvider(
      entered: entered.continuation,
      release: release.stream
    )
    let workflow = VoiceInputASRWorkflow(
      modelProvider: provider,
      transcriber: UnusedTranscriber()
    )
    let store = LockedProbeStore(command: nil)
    let service = VoiceInputCaptureService(
      store: store,
      captureURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).caf"),
      asrWorkflow: workflow,
      sessionFinalizer: VoiceInputSessionFinalizer(
        history: UnusedHistoryStore()
      )
    )
    let firstSessionID = UUID()
    let firstStart = Task {
      try await service.start(sessionID: firstSessionID)
    }
    for await _ in entered.stream.prefix(1) {}

    do {
      try await service.start(sessionID: UUID())
      XCTFail("A second start must not enter model preparation.")
    } catch {
      XCTAssertEqual(error as? VoiceInputCaptureError, .alreadyRecording)
    }

    release.continuation.finish()
    do {
      try await firstStart.value
      XCTFail("The released test prewarm must fail.")
    } catch {
      XCTAssertEqual(error as? CaptureServiceTestError, .released)
    }
    let providerCallCount = await provider.callCount
    XCTAssertEqual(providerCallCount, 1)
    XCTAssertEqual(try store.readSnapshot().sessionID, firstSessionID)
    XCTAssertEqual(try store.readSnapshot().phase, .failed)
  }
}

private enum CaptureServiceTestError: Error {
  case concurrentStart
  case released
  case unused
}

private actor BlockingASRModelProvider: VoiceInputASRModelProviding {
  private let entered: AsyncStream<Void>.Continuation
  private let release: AsyncStream<Void>
  private(set) var callCount = 0

  init(
    entered: AsyncStream<Void>.Continuation,
    release: AsyncStream<Void>
  ) {
    self.entered = entered
    self.release = release
  }

  func selectedASRModel() async throws -> VoiceInputInstalledModelPackage {
    callCount += 1
    guard callCount == 1 else {
      throw CaptureServiceTestError.concurrentStart
    }
    entered.yield()
    for await _ in release {}
    throw CaptureServiceTestError.released
  }
}

private struct UnusedTranscriber: VoiceInputTranscribing {
  func prewarm(model _: VoiceInputInstalledModelPackage) async throws {
    throw CaptureServiceTestError.unused
  }

  func transcribe(
    audioURL _: URL,
    model _: VoiceInputInstalledModelPackage
  ) async throws -> VoiceInputRawTranscript {
    throw CaptureServiceTestError.unused
  }
}

private struct UnusedHistoryStore: VoiceInputHistoryStoring {
  func save(
    sessionID _: UUID,
    startedAt _: Date,
    endedAt _: Date,
    transcript _: VoiceInputProcessedTranscript,
    sourceAudioURL _: URL
  ) async throws -> VoiceInputHistorySession {
    throw CaptureServiceTestError.unused
  }
}

private final class LockedProbeStore: VoiceInputStateStoring, Sendable {
  private struct State: Sendable {
    var snapshot = VoiceInputSnapshot.idle(sequence: 0)
    var command: VoiceInputCommand?
  }

  private let state: Mutex<State>

  init(command: VoiceInputCommand?) {
    state = Mutex(State(command: command))
  }

  func readSnapshot() throws -> VoiceInputSnapshot {
    state.withLock { $0.snapshot }
  }

  func writeSnapshot(_ snapshot: VoiceInputSnapshot) throws {
    state.withLock { $0.snapshot = snapshot }
  }

  func readCommand() throws -> VoiceInputCommand? {
    state.withLock { $0.command }
  }

  func writeCommand(_ command: VoiceInputCommand) throws {
    try state.withLock { state in
      guard state.command == nil else {
        throw VoiceInputStoreError.commandPending
      }
      state.command = command
    }
  }

  func consumeCommand() throws -> VoiceInputCommand? {
    state.withLock { state in
      defer { state.command = nil }
      return state.command
    }
  }
}
