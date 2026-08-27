import Foundation
import XCTest

@testable import VoiceProbeShared

final class VoiceProbeKeyboardPolicyTest: XCTestCase {
  func testColdKeyboardRequiresTruthfulManualActivation() {
    let decision = VoiceProbeKeyboardPolicy().microphoneDecision(
      snapshot: .idle(sequence: 1),
      hasFullAccess: true,
      lastInsertionReceipt: nil,
      now: Date(timeIntervalSince1970: 10)
    )

    XCTAssertEqual(decision, .manualActivationRequired)
  }

  func testKeyboardWithoutFullAccessRemainsUsableButVoiceIsUnavailable() {
    let decision = VoiceProbeKeyboardPolicy().microphoneDecision(
      snapshot: .idle(sequence: 1),
      hasFullAccess: false,
      lastInsertionReceipt: nil,
      now: Date(timeIntervalSince1970: 10)
    )

    XCTAssertEqual(decision, .requiresFullAccess)
  }

  func testWarmRecordingCanBeStoppedThroughItsExactSession() {
    let sessionID = UUID()
    let decision = VoiceProbeKeyboardPolicy(staleAfter: 3).microphoneDecision(
      snapshot: .recording(
        sessionID: sessionID,
        sequence: 2,
        heartbeatAt: Date(timeIntervalSince1970: 9)
      ),
      hasFullAccess: true,
      lastInsertionReceipt: nil,
      now: Date(timeIntervalSince1970: 10)
    )

    XCTAssertEqual(decision, .requestStop(sessionID: sessionID))
  }

  func testStaleRecordingNeverPretendsToBeLive() {
    let decision = VoiceProbeKeyboardPolicy(staleAfter: 3).microphoneDecision(
      snapshot: .recording(
        sessionID: UUID(),
        sequence: 2,
        heartbeatAt: Date(timeIntervalSince1970: 1)
      ),
      hasFullAccess: true,
      lastInsertionReceipt: nil,
      now: Date(timeIntervalSince1970: 10)
    )

    XCTAssertEqual(decision, .serviceStale)
  }

  func testReadyTextIsInsertedAtMostOnce() {
    let sessionID = UUID()
    let snapshot = VoiceProbeSnapshot.ready(
      sessionID: sessionID,
      sequence: 3,
      text: "Local result"
    )
    let policy = VoiceProbeKeyboardPolicy()

    XCTAssertEqual(
      policy.microphoneDecision(
        snapshot: snapshot,
        hasFullAccess: true,
        lastInsertionReceipt: nil,
        now: Date()
      ),
      .insert(sessionID: sessionID, sequence: 3, text: "Local result")
    )
    XCTAssertEqual(
      policy.microphoneDecision(
        snapshot: snapshot,
        hasFullAccess: true,
        lastInsertionReceipt: VoiceProbeInsertionReceipt(
          sessionID: sessionID,
          sequence: 3
        ),
        now: Date()
      ),
      .alreadyInserted
    )
    XCTAssertEqual(
      policy.microphoneDecision(
        snapshot: snapshot,
        hasFullAccess: true,
        lastInsertionReceipt: VoiceProbeInsertionReceipt(
          sessionID: UUID(),
          sequence: 3
        ),
        now: Date()
      ),
      .insert(sessionID: sessionID, sequence: 3, text: "Local result")
    )
  }

  func testTranscribingRequiresAnOwnedSession() {
    let decision = VoiceProbeKeyboardPolicy().microphoneDecision(
      snapshot: VoiceProbeSnapshot(
        phase: .transcribing,
        sessionID: nil,
        sequence: 4,
        heartbeatAt: nil,
        text: nil
      ),
      hasFullAccess: true,
      lastInsertionReceipt: nil,
      now: Date()
    )

    XCTAssertEqual(decision, .serviceStale)
  }

  func testCommandPolicyAcceptsOnlyCurrentCommands() {
    let now = Date(timeIntervalSince1970: 100)
    let policy = VoiceProbeCommandPolicy(maximumAge: 3)

    XCTAssertTrue(
      policy.accepts(
        .start(sessionID: UUID(), issuedAt: now.addingTimeInterval(-3)),
        now: now
      )
    )
    XCTAssertFalse(
      policy.accepts(
        .start(sessionID: UUID(), issuedAt: now.addingTimeInterval(-3.001)),
        now: now
      )
    )
  }

  func testCommandPolicyRejectsFutureCommands() {
    let now = Date(timeIntervalSince1970: 100)

    XCTAssertFalse(
      VoiceProbeCommandPolicy().accepts(
        .stop(sessionID: UUID(), issuedAt: now.addingTimeInterval(0.001)),
        now: now
      )
    )
  }
}
