import Foundation
import XCTest

@testable import VoiceInputShared

final class VoiceInputInsertionRecoveryPolicyTest: XCTestCase {
  func testExactUnchangedJourneyAllowsOneExplicitRetryThenCopyOnly() {
    let fixture = RecoveryPolicyFixture()
    let policy = VoiceInputInsertionRecoveryPolicy()

    XCTAssertEqual(
      policy.decision(
        for: .retry,
        recovery: fixture.recovery,
        snapshot: fixture.snapshot,
        receipt: fixture.receipt,
        documentIdentifier: fixture.documentIdentifier,
        hostChangeRevision: 4
      ),
      .perform
    )
    let afterRetry = fixture.recovery.recordingRetry()
    XCTAssertEqual(
      policy.decision(
        for: .retry,
        recovery: afterRetry,
        snapshot: fixture.snapshot,
        receipt: fixture.receipt,
        documentIdentifier: fixture.documentIdentifier,
        hostChangeRevision: 4
      ),
      .retryLimitReached
    )
    XCTAssertEqual(
      policy.decision(
        for: .copy,
        recovery: afterRetry,
        snapshot: fixture.snapshot,
        receipt: fixture.receipt,
        documentIdentifier: fixture.documentIdentifier,
        hostChangeRevision: 4
      ),
      .perform
    )
  }

  func testChangedTargetSessionSequenceOrTextRecoversFromHistory() {
    let fixture = RecoveryPolicyFixture()
    let policy = VoiceInputInsertionRecoveryPolicy()
    let mismatches:
      [(
        VoiceInputSnapshot,
        VoiceInputInsertionReceipt,
        UUID,
        UInt64
      )] = [
        (fixture.snapshot, fixture.receipt, UUID(), 4),
        (fixture.snapshot, fixture.receipt, fixture.documentIdentifier, 5),
        (
          .ready(sessionID: UUID(), sequence: 8, text: fixture.recovery.text),
          fixture.receipt,
          fixture.documentIdentifier,
          4
        ),
        (
          .ready(sessionID: fixture.recovery.sessionID, sequence: 9, text: fixture.recovery.text),
          fixture.receipt,
          fixture.documentIdentifier,
          4
        ),
        (
          .ready(sessionID: fixture.recovery.sessionID, sequence: 8, text: "Changed"),
          fixture.receipt,
          fixture.documentIdentifier,
          4
        ),
        (
          fixture.snapshot,
          VoiceInputInsertionReceipt(sessionID: fixture.recovery.sessionID, sequence: 7),
          fixture.documentIdentifier,
          4
        ),
      ]

    for (snapshot, receipt, documentIdentifier, revision) in mismatches {
      XCTAssertEqual(
        policy.decision(
          for: .copy,
          recovery: fixture.recovery,
          snapshot: snapshot,
          receipt: receipt,
          documentIdentifier: documentIdentifier,
          hostChangeRevision: revision
        ),
        .recoverFromHistory
      )
    }
  }

  func testUntrustedSnapshotOrMissingReceiptRecoversFromHistory() {
    let fixture = RecoveryPolicyFixture()
    let policy = VoiceInputInsertionRecoveryPolicy()
    let snapshots: [VoiceInputSnapshot] = [
      .idle(sequence: 1),
      .recording(
        sessionID: fixture.recovery.sessionID,
        sequence: 2,
        heartbeatAt: .now
      ),
      .transcribing(
        sessionID: fixture.recovery.sessionID,
        sequence: 3,
        heartbeatAt: .now
      ),
      VoiceInputSnapshot(
        phase: .failed,
        sessionID: fixture.recovery.sessionID,
        sequence: 4,
        heartbeatAt: nil,
        text: nil
      ),
      VoiceInputSnapshot(
        schemaRevision: VoiceInputSnapshot.schemaRevision + 1,
        phase: .ready,
        sessionID: fixture.recovery.sessionID,
        sequence: fixture.recovery.resultSequence,
        heartbeatAt: nil,
        text: fixture.recovery.text
      ),
    ]

    for snapshot in snapshots {
      XCTAssertEqual(
        policy.decision(
          for: .copy,
          recovery: fixture.recovery,
          snapshot: snapshot,
          receipt: fixture.receipt,
          documentIdentifier: fixture.documentIdentifier,
          hostChangeRevision: 4
        ),
        .recoverFromHistory
      )
    }
    XCTAssertEqual(
      policy.decision(
        for: .copy,
        recovery: fixture.recovery,
        snapshot: fixture.snapshot,
        receipt: nil,
        documentIdentifier: fixture.documentIdentifier,
        hostChangeRevision: 4
      ),
      .recoverFromHistory
    )
  }

  func testLocalCopyIsByteBoundAndExpiresOnDevice() throws {
    let now = Date(timeIntervalSince1970: 100)
    let policy = VoiceInputLocalCopyPolicy(
      maximumUTF8ByteCount: 4,
      lifetime: 600
    )

    XCTAssertEqual(
      try policy.payload(text: "éé", now: now),
      VoiceInputLocalCopyPayload(
        text: "éé",
        expiresAt: Date(timeIntervalSince1970: 700)
      )
    )
    XCTAssertThrowsError(try policy.payload(text: "", now: now)) { error in
      XCTAssertEqual(error as? VoiceInputLocalCopyError, .emptyText)
    }
    XCTAssertThrowsError(try policy.payload(text: "ééé", now: now)) { error in
      XCTAssertEqual(error as? VoiceInputLocalCopyError, .textTooLarge(limit: 4))
    }
  }

  func testLocalCopyRejectsInvalidBounds() {
    let now = Date(timeIntervalSince1970: 100)
    let policies = [
      VoiceInputLocalCopyPolicy(maximumUTF8ByteCount: 0, lifetime: 600),
      VoiceInputLocalCopyPolicy(maximumUTF8ByteCount: 1, lifetime: 0),
      VoiceInputLocalCopyPolicy(maximumUTF8ByteCount: 1, lifetime: .infinity),
    ]

    for policy in policies {
      XCTAssertThrowsError(try policy.payload(text: "x", now: now)) { error in
        XCTAssertEqual(error as? VoiceInputLocalCopyError, .invalidConfiguration)
      }
    }
  }
}

private struct RecoveryPolicyFixture {
  let documentIdentifier = UUID()
  let recovery: VoiceInputInsertionRecovery
  let snapshot: VoiceInputSnapshot
  let receipt: VoiceInputInsertionReceipt

  init() {
    let sessionID = UUID()
    recovery = VoiceInputInsertionRecovery(
      sessionID: sessionID,
      resultSequence: 8,
      text: "Recover exactly once.",
      target: VoiceInputDeliveryTarget(
        sessionID: sessionID,
        documentIdentifier: documentIdentifier,
        hostChangeRevision: 4,
        stopRequestedAfterSequence: 7
      )
    )
    snapshot = .ready(
      sessionID: sessionID,
      sequence: 8,
      text: recovery.text
    )
    receipt = VoiceInputInsertionReceipt(sessionID: sessionID, sequence: 8)
  }
}
