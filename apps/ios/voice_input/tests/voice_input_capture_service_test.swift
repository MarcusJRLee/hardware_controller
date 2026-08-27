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
