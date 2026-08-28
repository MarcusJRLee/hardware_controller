import Foundation
import Testing

@testable import HardwareControllerCore

struct VoiceHistoryRecoveryPlannerTest {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test
  func interruptedExpirationIsRestoredOrDiscardedFromDatabaseEvidence() {
    let retainedID = identifier(1)
    let expiredID = identifier(2)
    let retainedQuarantine = quarantineFilename(
      sessionID: retainedID,
      operationID: identifier(11)
    )
    let expiredQuarantine = quarantineFilename(
      sessionID: expiredID,
      operationID: identifier(12)
    )

    let plan = VoiceHistoryRecoveryPlanner.plan(
      sessions: [
        VoiceHistoryRecoverySessionDescriptor(
          id: retainedID,
          audioFilename: "\(retainedID.uuidString).caf",
          audioExpirationReason: nil
        ),
        VoiceHistoryRecoverySessionDescriptor(
          id: expiredID,
          audioFilename: nil,
          audioExpirationReason: .byteLimit
        ),
      ],
      artifacts: [
        artifact(retainedQuarantine),
        artifact(expiredQuarantine),
      ],
      now: now
    )

    #expect(
      plan.actions == [
        .discardCommittedQuarantine(filename: expiredQuarantine),
        .restoreQuarantine(
          filename: retainedQuarantine,
          destinationFilename: "\(retainedID.uuidString).caf",
          sessionID: retainedID
        ),
      ]
    )
    #expect(plan.issues.isEmpty)
  }

  @Test
  func orphanAudioUsesOriginalIdentifierOnlyOnce() {
    let sessionID = identifier(3)
    let finalFilename = "\(sessionID.uuidString).caf"
    let partialFilename = "\(sessionID.uuidString).partial"

    let plan = VoiceHistoryRecoveryPlanner.plan(
      sessions: [],
      artifacts: [
        artifact(partialFilename),
        artifact(finalFilename),
      ],
      now: now
    )

    #expect(
      plan.actions == [
        .recover(
          filename: finalFilename,
          preferredSessionID: sessionID,
          kind: .orphanedFinalization
        ),
        .recover(
          filename: partialFilename,
          preferredSessionID: nil,
          kind: .interruptedCapture
        ),
      ]
    )
    #expect(plan.issues.isEmpty)
  }

  @Test
  func orphanQuarantineBecomesRecoverableAudio() {
    let quarantine = quarantineFilename(
      sessionID: identifier(4),
      operationID: identifier(14)
    )

    let plan = VoiceHistoryRecoveryPlanner.plan(
      sessions: [],
      artifacts: [artifact(quarantine)],
      now: now
    )

    #expect(
      plan.actions == [
        .recover(
          filename: quarantine,
          preferredSessionID: identifier(4),
          kind: .interruptedExpiration
        )
      ]
    )
  }

  @Test
  func unreadableOwnedAudioIsPreservedForTwentyFourHours() {
    let recent = "\(identifier(5).uuidString).partial"
    let stale = "\(identifier(6).uuidString).caf"
    let referenced = "\(identifier(7).uuidString).caf"
    let plan = VoiceHistoryRecoveryPlanner.plan(
      sessions: [
        VoiceHistoryRecoverySessionDescriptor(
          id: identifier(7),
          audioFilename: referenced,
          audioExpirationReason: nil
        )
      ],
      artifacts: [
        artifact(
          recent,
          modifiedAt: now.addingTimeInterval(-86_399),
          isReadableAudio: false
        ),
        artifact(
          stale,
          modifiedAt: now.addingTimeInterval(-86_401),
          isReadableAudio: false
        ),
        artifact(
          referenced,
          modifiedAt: now.addingTimeInterval(-172_800),
          isReadableAudio: false
        ),
      ],
      now: now
    )

    #expect(
      plan.actions == [.removeStaleUnreadable(filename: stale)]
    )
    #expect(
      plan.issues == [
        .unreadableArtifact(filename: recent),
        .unreadableArtifact(filename: referenced),
      ]
    )
  }

  @Test
  func unrelatedFilesAndAlreadyReferencedAudioNeedNoAction() {
    let sessionID = identifier(8)
    let finalFilename = "\(sessionID.uuidString).caf"

    let plan = VoiceHistoryRecoveryPlanner.plan(
      sessions: [
        VoiceHistoryRecoverySessionDescriptor(
          id: sessionID,
          audioFilename: finalFilename,
          audioExpirationReason: nil
        )
      ],
      artifacts: [
        artifact(finalFilename),
        artifact("notes.txt"),
        artifact("malformed.partial"),
      ],
      now: now
    )

    #expect(plan.actions.isEmpty)
    #expect(plan.issues.isEmpty)
  }

  private func artifact(
    _ filename: String,
    modifiedAt: Date? = nil,
    isReadableAudio: Bool = true
  ) -> VoiceHistoryRecoveryArtifactDescriptor {
    VoiceHistoryRecoveryArtifactDescriptor(
      filename: filename,
      modifiedAt: modifiedAt ?? now,
      isReadableAudio: isReadableAudio
    )
  }

  private func quarantineFilename(
    sessionID: UUID,
    operationID: UUID
  ) -> String {
    ".expiring_\(sessionID.uuidString)_\(operationID.uuidString).caf"
  }

  private func identifier(_ suffix: Int) -> UUID {
    guard
      let value = UUID(
        uuidString: String(
          format: "00000000-0000-0000-0000-%012d",
          suffix
        )
      )
    else {
      fatalError("The fixed test identifier must be valid.")
    }
    return value
  }
}
