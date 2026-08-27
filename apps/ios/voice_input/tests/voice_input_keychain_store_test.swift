import Foundation
import XCTest

@testable import VoiceInputShared

final class VoiceInputKeychainStoreTest: XCTestCase {
  private var store: VoiceInputKeychainStore!

  override func setUpWithError() throws {
    store = VoiceInputKeychainStore(
      service: "com.longdevity.hardwarecontroller.voiceinput.tests.\(UUID().uuidString)"
    )
    try store.removeAll()
  }

  override func tearDownWithError() throws {
    try store.removeAll()
    store = nil
  }

  func testSnapshotRoundTripsWithoutCloudSynchronization() throws {
    let expected = VoiceInputSnapshot.recording(
      sessionID: UUID(),
      sequence: 3,
      heartbeatAt: Date(timeIntervalSince1970: 42)
    )
    try store.writeSnapshot(expected)
    XCTAssertEqual(try store.readSnapshot(), expected)
  }

  func testMissingSnapshotIsIdle() throws {
    XCTAssertEqual(try store.readSnapshot(), .idle(sequence: 0))
  }

  func testCommandCreationIsAnAtomicSingleSlot() throws {
    let first = VoiceInputCommand.stop(
      sessionID: UUID(),
      issuedAt: Date(timeIntervalSince1970: 84)
    )
    try store.writeCommand(first)

    XCTAssertThrowsError(
      try store.writeCommand(
        .start(
          sessionID: UUID(),
          issuedAt: Date(timeIntervalSince1970: 126)
        )
      )
    ) { error in
      XCTAssertEqual(error as? VoiceInputStoreError, .commandPending)
    }
    XCTAssertEqual(try store.consumeCommand(), first)
    XCTAssertNil(try store.consumeCommand())
  }

  func testOversizedSnapshotIsRejectedBeforeKeychainWrite() throws {
    store = VoiceInputKeychainStore(
      service: "com.longdevity.hardwarecontroller.voiceinput.tests.\(UUID().uuidString)",
      maximumRecordByteCount: 64
    )
    let oversized = VoiceInputSnapshot.ready(
      sessionID: UUID(),
      sequence: 1,
      text: String(repeating: "a", count: 64)
    )

    XCTAssertThrowsError(try store.writeSnapshot(oversized)) { error in
      XCTAssertEqual(error as? VoiceInputStoreError, .recordTooLarge(limit: 64))
    }
    XCTAssertEqual(try store.readSnapshot(), .idle(sequence: 0))
  }

  func testKeyboardPresenceRoundTripsWithoutCloudSynchronization() throws {
    let observedAt = Date(timeIntervalSince1970: 42)

    try store.markKeyboardObserved(at: observedAt)

    XCTAssertEqual(try store.readKeyboardObservedAt(), observedAt)
  }

  func testSnapshotHandoffLatencyHasHeadroomForInteractiveUse() throws {
    let clock = ContinuousClock()
    var samples: [Double] = []
    for sequence in 1...100 {
      let snapshot = VoiceInputSnapshot.recording(
        sessionID: UUID(),
        sequence: UInt64(sequence),
        heartbeatAt: Date(timeIntervalSince1970: Double(sequence))
      )
      let start = clock.now
      try store.writeSnapshot(snapshot)
      XCTAssertEqual(try store.readSnapshot(), snapshot)
      samples.append(milliseconds(clock.now - start))
    }

    let sorted = samples.sorted()
    let p50 = sorted[49]
    let p95 = sorted[94]
    let maximum = try XCTUnwrap(sorted.last)
    print(
      "VOICE_PROBE_KEYCHAIN n=100 p50=\(p50)ms p95=\(p95)ms max=\(maximum)ms"
    )
    XCTAssertLessThan(p95, 50)
  }

  private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }
}
