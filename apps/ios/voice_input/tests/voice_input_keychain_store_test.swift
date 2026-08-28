import Foundation
import Security
import XCTest

@testable import VoiceInputShared

final class VoiceInputKeychainStoreTest: XCTestCase {
  private var store: VoiceInputKeychainStore!
  private var service: String!

  override func setUpWithError() throws {
    service = "com.longdevity.hardwarecontroller.voiceinput.tests.\(UUID().uuidString)"
    store = VoiceInputKeychainStore(service: service)
    try store.removeAll()
  }

  override func tearDownWithError() throws {
    try store.removeAll()
    store = nil
    service = nil
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
      styleKind: .technical,
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

  func testMalformedCommandIsDeletedAfterOneConsumptionAttempt() throws {
    let malformed = Data(
      """
      {"issuedAt":42000,"kind":"stop","schemaRevision":2,"sessionID":"\(UUID().uuidString)","styleKind":"unknown"}
      """.utf8
    )
    let status = SecItemAdd(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service as Any,
        kSecAttrAccount: "command",
        kSecAttrSynchronizable: false,
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecValueData: malformed,
      ] as CFDictionary,
      nil
    )
    XCTAssertEqual(status, errSecSuccess)

    XCTAssertThrowsError(try store.consumeCommand()) { error in
      XCTAssertEqual(error as? VoiceInputStoreError, .invalidCommand)
    }
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

  func testInsertionReceiptClaimIsDurableAndAtMostOncePerSession() throws {
    let first = VoiceInputInsertionReceipt(sessionID: UUID(), sequence: 2)
    let rePublished = VoiceInputInsertionReceipt(
      sessionID: first.sessionID,
      sequence: 3
    )
    let next = VoiceInputInsertionReceipt(sessionID: UUID(), sequence: 4)

    XCTAssertTrue(try store.claimInsertion(first))
    XCTAssertEqual(try store.readInsertionReceipt(), first)
    XCTAssertFalse(try store.claimInsertion(rePublished))
    XCTAssertEqual(try store.readInsertionReceipt(), first)
    XCTAssertTrue(try store.claimInsertion(next))
    XCTAssertEqual(try store.readInsertionReceipt(), next)
  }

  func testWarmKeyboardHandoffStopsWithStyleAndInsertsOnce() throws {
    let sessionID = UUID()
    let now = Date(timeIntervalSince1970: 42)
    let policy = VoiceInputKeyboardPolicy()
    try store.writeSnapshot(
      .recording(sessionID: sessionID, sequence: 1, heartbeatAt: now)
    )

    XCTAssertEqual(
      policy.microphoneDecision(
        snapshot: try store.readSnapshot(),
        hasFullAccess: true,
        lastInsertionReceipt: nil,
        now: now
      ),
      .requestStop(sessionID: sessionID)
    )
    try store.writeCommand(
      .stop(sessionID: sessionID, styleKind: .formal, issuedAt: now)
    )
    XCTAssertEqual(try store.consumeCommand()?.styleKind, .formal)

    let ready = VoiceInputSnapshot.ready(
      sessionID: sessionID,
      sequence: 2,
      text: "One formal result."
    )
    try store.writeSnapshot(ready)
    XCTAssertEqual(
      policy.microphoneDecision(
        snapshot: try store.readSnapshot(),
        hasFullAccess: true,
        lastInsertionReceipt: nil,
        now: now
      ),
      .insert(
        sessionID: sessionID,
        sequence: 2,
        text: "One formal result."
      )
    )
    XCTAssertEqual(
      policy.microphoneDecision(
        snapshot: ready,
        hasFullAccess: true,
        lastInsertionReceipt: VoiceInputInsertionReceipt(
          sessionID: sessionID,
          sequence: 2
        ),
        now: now
      ),
      .alreadyInserted
    )
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
