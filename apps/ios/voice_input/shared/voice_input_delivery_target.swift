import Foundation

public struct VoiceInputDeliveryTarget: Equatable, Sendable {
  public let sessionID: UUID
  public let documentIdentifier: UUID
  public let hostChangeRevision: UInt64
  public let stopRequestedAfterSequence: UInt64

  public init(
    sessionID: UUID,
    documentIdentifier: UUID,
    hostChangeRevision: UInt64,
    stopRequestedAfterSequence: UInt64
  ) {
    self.sessionID = sessionID
    self.documentIdentifier = documentIdentifier
    self.hostChangeRevision = hostChangeRevision
    self.stopRequestedAfterSequence = stopRequestedAfterSequence
  }
}

public enum VoiceInputDeliveryTargetDecision: Equatable, Sendable {
  case deliver
  case recoverFromHistory
}

public struct VoiceInputDeliveryTargetPolicy: Equatable, Sendable {
  public init() {}

  public func decision(
    sessionID: UUID,
    resultSequence: UInt64,
    documentIdentifier: UUID,
    hostChangeRevision: UInt64,
    target: VoiceInputDeliveryTarget?
  ) -> VoiceInputDeliveryTargetDecision {
    guard
      let target,
      target.sessionID == sessionID,
      resultSequence > target.stopRequestedAfterSequence,
      target.documentIdentifier == documentIdentifier,
      target.hostChangeRevision == hostChangeRevision
    else {
      return .recoverFromHistory
    }
    return .deliver
  }
}
