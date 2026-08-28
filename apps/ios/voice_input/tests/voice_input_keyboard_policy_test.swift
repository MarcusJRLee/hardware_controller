import Foundation
import XCTest

@testable import VoiceInputShared

final class VoiceInputKeyboardPolicyTest: XCTestCase {
  func testColdKeyboardRequiresTruthfulManualActivation() {
    let decision = VoiceInputKeyboardPolicy().microphoneDecision(
      snapshot: .idle(sequence: 1),
      hasFullAccess: true,
      lastInsertionReceipt: nil,
      now: Date(timeIntervalSince1970: 10)
    )

    XCTAssertEqual(decision, .manualActivationRequired)
  }

  func testKeyboardWithoutFullAccessRemainsUsableButVoiceIsUnavailable() {
    let decision = VoiceInputKeyboardPolicy().microphoneDecision(
      snapshot: .idle(sequence: 1),
      hasFullAccess: false,
      lastInsertionReceipt: nil,
      now: Date(timeIntervalSince1970: 10)
    )

    XCTAssertEqual(decision, .requiresFullAccess)
  }

  func testUnsupportedFieldNeverStopsOrDeliversVoice() {
    let decision = VoiceInputKeyboardPolicy().microphoneDecision(
      snapshot: .recording(
        sessionID: UUID(),
        sequence: 1,
        heartbeatAt: Date(timeIntervalSince1970: 10)
      ),
      hasFullAccess: true,
      fieldEligibility: .unsupported,
      lastInsertionReceipt: nil,
      now: Date(timeIntervalSince1970: 10)
    )

    XCTAssertEqual(decision, .unsupportedField)
  }

  func testWarmRecordingCanBeStoppedThroughItsExactSession() {
    let sessionID = UUID()
    let decision = VoiceInputKeyboardPolicy(staleAfter: 3).microphoneDecision(
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
    let decision = VoiceInputKeyboardPolicy(staleAfter: 3).microphoneDecision(
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

  func testUnknownSnapshotRevisionRequiresServiceRestart() {
    let decision = VoiceInputKeyboardPolicy().microphoneDecision(
      snapshot: VoiceInputSnapshot(
        schemaRevision: VoiceInputSnapshot.schemaRevision + 1,
        phase: .recording,
        sessionID: UUID(),
        sequence: 2,
        heartbeatAt: Date(timeIntervalSince1970: 10),
        text: nil
      ),
      hasFullAccess: true,
      lastInsertionReceipt: nil,
      now: Date(timeIntervalSince1970: 10)
    )

    XCTAssertEqual(decision, .serviceStale)
  }

  func testReadyTextIsInsertedAtMostOnce() {
    let sessionID = UUID()
    let snapshot = VoiceInputSnapshot.ready(
      sessionID: sessionID,
      sequence: 3,
      text: "Local result"
    )
    let policy = VoiceInputKeyboardPolicy()

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
        lastInsertionReceipt: VoiceInputInsertionReceipt(
          sessionID: sessionID,
          sequence: 3
        ),
        now: Date()
      ),
      .alreadyInserted
    )
    XCTAssertEqual(
      policy.microphoneDecision(
        snapshot: VoiceInputSnapshot.ready(
          sessionID: sessionID,
          sequence: 4,
          text: "Re-published local result"
        ),
        hasFullAccess: true,
        lastInsertionReceipt: VoiceInputInsertionReceipt(
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
        lastInsertionReceipt: VoiceInputInsertionReceipt(
          sessionID: UUID(),
          sequence: 3
        ),
        now: Date()
      ),
      .insert(sessionID: sessionID, sequence: 3, text: "Local result")
    )
  }

  func testWarmKeyboardJourneyCarriesStyleAndInsertsOneMatchingResult() {
    let sessionID = UUID()
    let policy = VoiceInputKeyboardPolicy()
    let now = Date(timeIntervalSince1970: 10)
    let recording = VoiceInputSnapshot.recording(
      sessionID: sessionID,
      sequence: 1,
      heartbeatAt: now
    )

    XCTAssertEqual(
      policy.microphoneDecision(
        snapshot: recording,
        hasFullAccess: true,
        lastInsertionReceipt: nil,
        now: now
      ),
      .requestStop(sessionID: sessionID)
    )
    let stop = VoiceInputCommand.stop(
      sessionID: sessionID,
      styleKind: .formal,
      issuedAt: now
    )
    XCTAssertEqual(stop.styleKind, .formal)

    let ready = VoiceInputSnapshot.ready(
      sessionID: sessionID,
      sequence: 2,
      text: "Formatted once."
    )
    XCTAssertEqual(
      policy.microphoneDecision(
        snapshot: ready,
        hasFullAccess: true,
        lastInsertionReceipt: nil,
        now: now
      ),
      .insert(
        sessionID: sessionID,
        sequence: 2,
        text: "Formatted once."
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

  func testTranscribingRequiresAnOwnedSession() {
    let decision = VoiceInputKeyboardPolicy().microphoneDecision(
      snapshot: VoiceInputSnapshot(
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

  func testTranscribingRequiresACurrentHeartbeat() {
    let sessionID = UUID()
    let policy = VoiceInputKeyboardPolicy(staleAfter: 3)
    let now = Date(timeIntervalSince1970: 10)

    XCTAssertEqual(
      policy.microphoneDecision(
        snapshot: VoiceInputSnapshot(
          phase: .transcribing,
          sessionID: sessionID,
          sequence: 4,
          heartbeatAt: now.addingTimeInterval(-3),
          text: nil
        ),
        hasFullAccess: true,
        lastInsertionReceipt: nil,
        now: now
      ),
      .waitingForResult
    )
    for heartbeatAt in [nil, now.addingTimeInterval(-3.001), now.addingTimeInterval(0.001)] {
      XCTAssertEqual(
        policy.microphoneDecision(
          snapshot: VoiceInputSnapshot(
            phase: .transcribing,
            sessionID: sessionID,
            sequence: 4,
            heartbeatAt: heartbeatAt,
            text: nil
          ),
          hasFullAccess: true,
          lastInsertionReceipt: nil,
          now: now
        ),
        .serviceStale
      )
    }
  }

  func testCompletedSessionCannotBeRevivedByALateActiveSnapshot() {
    let sessionID = UUID()
    let now = Date(timeIntervalSince1970: 10)
    let receipt = VoiceInputInsertionReceipt(sessionID: sessionID, sequence: 8)

    for phase in [VoiceInputSnapshot.Phase.recording, .transcribing] {
      XCTAssertEqual(
        VoiceInputKeyboardPolicy().microphoneDecision(
          snapshot: VoiceInputSnapshot(
            phase: phase,
            sessionID: sessionID,
            sequence: 7,
            heartbeatAt: now,
            text: nil
          ),
          hasFullAccess: true,
          lastInsertionReceipt: receipt,
          now: now
        ),
        .alreadyInserted
      )
    }
  }

  func testCommandPolicyAcceptsOnlyCurrentCommands() {
    let now = Date(timeIntervalSince1970: 100)
    let policy = VoiceInputCommandPolicy(maximumAge: 3)

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
      VoiceInputCommandPolicy().accepts(
        .stop(
          sessionID: UUID(),
          styleKind: .natural,
          issuedAt: now.addingTimeInterval(0.001)
        ),
        now: now
      )
    )
  }

  func testLegacyStopWithoutStyleCannotFinalizeAResult() throws {
    let sessionID = UUID()
    let data = Data(
      """
      {"issuedAt":100000,"kind":"stop","schemaRevision":1,"sessionID":"\(sessionID.uuidString)"}
      """.utf8
    )
    let command = try VoiceInputJSON.decoder.decode(
      VoiceInputCommand.self,
      from: data
    )

    XCTAssertFalse(
      VoiceInputCommandPolicy().accepts(
        command,
        now: Date(timeIntervalSince1970: 100)
      )
    )
  }
}
