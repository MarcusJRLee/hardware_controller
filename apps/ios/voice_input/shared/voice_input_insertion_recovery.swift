import Foundation

public enum VoiceInputInsertionRecoveryAction: Equatable, Sendable {
  case retry
  case copy
}

public enum VoiceInputInsertionRecoveryDecision: Equatable, Sendable {
  case perform
  case retryLimitReached
  case recoverFromHistory
}

public struct VoiceInputInsertionRecovery: Equatable, Sendable {
  public let sessionID: UUID
  public let resultSequence: UInt64
  public let text: String
  public let target: VoiceInputDeliveryTarget
  public let retryCount: UInt8

  public init(
    sessionID: UUID,
    resultSequence: UInt64,
    text: String,
    target: VoiceInputDeliveryTarget,
    retryCount: UInt8 = 0
  ) {
    self.sessionID = sessionID
    self.resultSequence = resultSequence
    self.text = text
    self.target = target
    self.retryCount = retryCount
  }

  public func recordingRetry() -> VoiceInputInsertionRecovery {
    let (nextRetryCount, overflow) = retryCount.addingReportingOverflow(1)
    return VoiceInputInsertionRecovery(
      sessionID: sessionID,
      resultSequence: resultSequence,
      text: text,
      target: target,
      retryCount: overflow ? retryCount : nextRetryCount
    )
  }
}

public struct VoiceInputInsertionRecoveryPolicy: Equatable, Sendable {
  public let maximumRetryCount: UInt8 = 1

  public init() {}

  public func decision(
    for action: VoiceInputInsertionRecoveryAction,
    recovery: VoiceInputInsertionRecovery,
    snapshot: VoiceInputSnapshot,
    receipt: VoiceInputInsertionReceipt?,
    documentIdentifier: UUID,
    hostChangeRevision: UInt64
  ) -> VoiceInputInsertionRecoveryDecision {
    guard
      snapshot.schemaRevision == VoiceInputSnapshot.schemaRevision,
      snapshot.phase == .ready,
      snapshot.sessionID == recovery.sessionID,
      snapshot.sequence == recovery.resultSequence,
      snapshot.text == recovery.text,
      !recovery.text.isEmpty,
      receipt
        == VoiceInputInsertionReceipt(
          sessionID: recovery.sessionID,
          sequence: recovery.resultSequence
        ),
      VoiceInputDeliveryTargetPolicy().decision(
        sessionID: recovery.sessionID,
        resultSequence: recovery.resultSequence,
        documentIdentifier: documentIdentifier,
        hostChangeRevision: hostChangeRevision,
        target: recovery.target
      ) == .deliver
    else {
      return .recoverFromHistory
    }
    if action == .retry, recovery.retryCount >= maximumRetryCount {
      return .retryLimitReached
    }
    return .perform
  }
}
