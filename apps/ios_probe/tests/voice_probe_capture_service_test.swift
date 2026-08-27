import Foundation
import Synchronization
import VoiceProbeShared
import XCTest

@testable import VoiceProbe

final class VoiceProbeCaptureServiceTest: XCTestCase {
  func testStaleStartCommandIsConsumedWithoutStartingCapture() async throws {
    let store = LockedProbeStore(
      command: .start(
        sessionID: UUID(),
        issuedAt: Date(timeIntervalSinceNow: -60)
      )
    )
    let captureURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).caf")
    let service = VoiceProbeCaptureService(store: store, captureURL: captureURL)

    try await service.processPendingCommand()

    XCTAssertNil(try store.readCommand())
    XCTAssertEqual(try store.readSnapshot(), .idle(sequence: 0))
    XCTAssertFalse(FileManager.default.fileExists(atPath: captureURL.path))
  }
}

private final class LockedProbeStore: VoiceProbeStateStoring, Sendable {
  private struct State: Sendable {
    var snapshot = VoiceProbeSnapshot.idle(sequence: 0)
    var command: VoiceProbeCommand?
  }

  private let state: Mutex<State>

  init(command: VoiceProbeCommand?) {
    state = Mutex(State(command: command))
  }

  func readSnapshot() throws -> VoiceProbeSnapshot {
    state.withLock { $0.snapshot }
  }

  func writeSnapshot(_ snapshot: VoiceProbeSnapshot) throws {
    state.withLock { $0.snapshot = snapshot }
  }

  func readCommand() throws -> VoiceProbeCommand? {
    state.withLock { $0.command }
  }

  func writeCommand(_ command: VoiceProbeCommand) throws {
    try state.withLock { state in
      guard state.command == nil else {
        throw VoiceProbeStoreError.commandPending
      }
      state.command = command
    }
  }

  func consumeCommand() throws -> VoiceProbeCommand? {
    state.withLock { state in
      defer { state.command = nil }
      return state.command
    }
  }
}
