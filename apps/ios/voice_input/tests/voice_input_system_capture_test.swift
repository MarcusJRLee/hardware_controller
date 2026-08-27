import Foundation
import Synchronization
import VoiceInputShared
import XCTest

final class VoiceInputSystemCaptureTest: XCTestCase {
  func testInactiveSystemSurfaceQueuesOneExactStart() throws {
    let store = SystemCaptureProbeStore(snapshot: .idle(sequence: 4))
    let sessionID = UUID()
    let now = Date(timeIntervalSince1970: 100)

    let outcome = try VoiceInputSystemCaptureCommandHandler().setRecording(
      true,
      store: store,
      requestedSessionID: sessionID,
      now: now
    )

    XCTAssertEqual(outcome, .queuedStart(sessionID: sessionID))
    XCTAssertEqual(
      try store.readCommand(),
      .start(sessionID: sessionID, issuedAt: now)
    )
  }

  func testFreshRecordingQueuesOneExactNaturalStop() throws {
    let sessionID = UUID()
    let now = Date(timeIntervalSince1970: 100)
    let store = SystemCaptureProbeStore(
      snapshot: .recording(
        sessionID: sessionID,
        sequence: 5,
        heartbeatAt: now.addingTimeInterval(-1)
      )
    )

    let outcome = try VoiceInputSystemCaptureCommandHandler().setRecording(
      false,
      store: store,
      requestedSessionID: UUID(),
      now: now
    )

    XCTAssertEqual(outcome, .queuedStop(sessionID: sessionID))
    XCTAssertEqual(
      try store.readCommand(),
      .stop(sessionID: sessionID, styleKind: .natural, issuedAt: now)
    )
  }

  func testFreshActiveStateIsIdempotentAndTranscribingCannotRestart() throws {
    let now = Date(timeIntervalSince1970: 100)
    let recording = SystemCaptureProbeStore(
      snapshot: .recording(
        sessionID: UUID(),
        sequence: 2,
        heartbeatAt: now
      )
    )
    let transcribing = SystemCaptureProbeStore(
      snapshot: .transcribing(
        sessionID: UUID(),
        sequence: 3,
        heartbeatAt: now
      )
    )
    let handler = VoiceInputSystemCaptureCommandHandler()

    XCTAssertEqual(
      try handler.setRecording(
        true,
        store: recording,
        requestedSessionID: UUID(),
        now: now
      ),
      .unchanged
    )
    XCTAssertEqual(
      try handler.setRecording(
        true,
        store: transcribing,
        requestedSessionID: UUID(),
        now: now
      ),
      .unchanged
    )
    XCTAssertNil(try recording.readCommand())
    XCTAssertNil(try transcribing.readCommand())
  }

  func testStaleRecordingRendersInactiveAndCannotQueueAStop() throws {
    let now = Date(timeIntervalSince1970: 100)
    let snapshot = VoiceInputSnapshot.recording(
      sessionID: UUID(),
      sequence: 2,
      heartbeatAt: now.addingTimeInterval(-4)
    )
    let store = SystemCaptureProbeStore(snapshot: snapshot)
    let policy = VoiceInputSystemCapturePolicy()

    XCTAssertFalse(policy.isRecording(snapshot: snapshot, now: now))
    XCTAssertEqual(
      try VoiceInputSystemCaptureCommandHandler().setRecording(
        false,
        store: store,
        requestedSessionID: UUID(),
        now: now
      ),
      .unchanged
    )
    XCTAssertNil(try store.readCommand())
  }

  func testFutureSnapshotFailsClosedWithoutReplacingState() throws {
    let now = Date(timeIntervalSince1970: 100)
    let snapshot = VoiceInputSnapshot(
      schemaRevision: VoiceInputSnapshot.schemaRevision + 1,
      phase: .idle,
      sessionID: nil,
      sequence: 9,
      heartbeatAt: nil,
      text: nil
    )
    let store = SystemCaptureProbeStore(snapshot: snapshot)

    let outcome = try VoiceInputSystemCaptureCommandHandler().setRecording(
      true,
      store: store,
      requestedSessionID: UUID(),
      now: now
    )

    XCTAssertEqual(outcome, .unchanged)
    XCTAssertNil(try store.readCommand())
    XCTAssertEqual(try store.readSnapshot(), snapshot)
  }

  func testPendingCommandIsNeverOverwritten() throws {
    let existing = VoiceInputCommand.start(
      sessionID: UUID(),
      issuedAt: Date(timeIntervalSince1970: 90)
    )
    let store = SystemCaptureProbeStore(
      snapshot: .idle(sequence: 0),
      command: existing
    )

    XCTAssertThrowsError(
      try VoiceInputSystemCaptureCommandHandler().setRecording(
        true,
        store: store,
        requestedSessionID: UUID(),
        now: Date(timeIntervalSince1970: 100)
      )
    ) { error in
      XCTAssertEqual(error as? VoiceInputStoreError, .commandPending)
    }
    XCTAssertEqual(try store.readCommand(), existing)
  }
}

private final class SystemCaptureProbeStore: VoiceInputStateStoring, Sendable {
  private struct State: Sendable {
    var snapshot: VoiceInputSnapshot
    var command: VoiceInputCommand?
  }

  private let state: Mutex<State>

  init(
    snapshot: VoiceInputSnapshot,
    command: VoiceInputCommand? = nil
  ) {
    state = Mutex(State(snapshot: snapshot, command: command))
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
    try state.withLock {
      guard $0.command == nil else {
        throw VoiceInputStoreError.commandPending
      }
      $0.command = command
    }
  }

  func consumeCommand() throws -> VoiceInputCommand? {
    state.withLock {
      let command = $0.command
      $0.command = nil
      return command
    }
  }
}
