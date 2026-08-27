import Foundation
import XCTest

@testable import VoiceInputShared

final class VoiceInputDeliveryTargetPolicyTest: XCTestCase {
  func testWarmJourneyStopsAndDeliversOnlyToItsOriginalGeneralTextDocument() {
    let sessionID = UUID()
    let documentIdentifier = UUID()
    let now = Date(timeIntervalSince1970: 10)
    let keyboardPolicy = VoiceInputKeyboardPolicy()

    XCTAssertEqual(
      keyboardPolicy.microphoneDecision(
        snapshot: .recording(
          sessionID: sessionID,
          sequence: 1,
          heartbeatAt: now
        ),
        hasFullAccess: true,
        fieldEligibility: .supported,
        lastInsertionReceipt: nil,
        now: now
      ),
      .requestStop(sessionID: sessionID)
    )
    let target = VoiceInputDeliveryTarget(
      sessionID: sessionID,
      documentIdentifier: documentIdentifier,
      hostChangeRevision: 4
    )
    XCTAssertEqual(
      keyboardPolicy.microphoneDecision(
        snapshot: .ready(
          sessionID: sessionID,
          sequence: 2,
          text: "Target-bound result."
        ),
        hasFullAccess: true,
        fieldEligibility: .supported,
        lastInsertionReceipt: nil,
        now: now
      ),
      .insert(
        sessionID: sessionID,
        sequence: 2,
        text: "Target-bound result."
      )
    )
    XCTAssertEqual(
      VoiceInputDeliveryTargetPolicy().decision(
        sessionID: sessionID,
        documentIdentifier: documentIdentifier,
        hostChangeRevision: 4,
        target: target
      ),
      .deliver
    )
  }

  func testOnlyTheExactSessionDocumentAndRevisionCanReceiveTheResult() {
    let sessionID = UUID()
    let documentIdentifier = UUID()
    let target = VoiceInputDeliveryTarget(
      sessionID: sessionID,
      documentIdentifier: documentIdentifier,
      hostChangeRevision: 4
    )
    let policy = VoiceInputDeliveryTargetPolicy()

    XCTAssertEqual(
      policy.decision(
        sessionID: sessionID,
        documentIdentifier: documentIdentifier,
        hostChangeRevision: 4,
        target: target
      ),
      .deliver
    )
    XCTAssertEqual(
      policy.decision(
        sessionID: UUID(),
        documentIdentifier: documentIdentifier,
        hostChangeRevision: 4,
        target: target
      ),
      .recoverFromHistory
    )
    XCTAssertEqual(
      policy.decision(
        sessionID: sessionID,
        documentIdentifier: UUID(),
        hostChangeRevision: 4,
        target: target
      ),
      .recoverFromHistory
    )
    XCTAssertEqual(
      policy.decision(
        sessionID: sessionID,
        documentIdentifier: documentIdentifier,
        hostChangeRevision: 5,
        target: target
      ),
      .recoverFromHistory
    )
    XCTAssertEqual(
      policy.decision(
        sessionID: sessionID,
        documentIdentifier: documentIdentifier,
        hostChangeRevision: 4,
        target: nil
      ),
      .recoverFromHistory
    )
  }
}
