import Foundation

public enum VoiceInputSystemCaptureCommandOutcome: Equatable, Sendable {
  case queuedStart(sessionID: UUID)
  case queuedStop(sessionID: UUID)
  case unchanged
}

public struct VoiceInputSystemCapturePolicy: Equatable, Sendable {
  public let staleAfter: TimeInterval

  public init(staleAfter: TimeInterval = 3) {
    self.staleAfter = staleAfter
  }

  public func isRecording(
    snapshot: VoiceInputSnapshot,
    now: Date
  ) -> Bool {
    guard
      snapshot.schemaRevision == VoiceInputSnapshot.schemaRevision,
      snapshot.phase == .recording,
      snapshot.sessionID != nil
    else {
      return false
    }
    return hasCurrentHeartbeat(snapshot.heartbeatAt, now: now)
  }

  public func command(
    settingRecording requestedRecording: Bool,
    snapshot: VoiceInputSnapshot,
    requestedSessionID: UUID,
    styleKind: VoiceInputStyleKind,
    now: Date
  ) -> VoiceInputCommand? {
    guard snapshot.schemaRevision == VoiceInputSnapshot.schemaRevision else {
      return nil
    }
    if requestedRecording {
      if isRecording(snapshot: snapshot, now: now)
        || isFinalizing(snapshot: snapshot, now: now)
      {
        return nil
      }
      return .start(sessionID: requestedSessionID, issuedAt: now)
    }
    guard isRecording(snapshot: snapshot, now: now), let sessionID = snapshot.sessionID else {
      return nil
    }
    return .stop(
      sessionID: sessionID,
      styleKind: styleKind,
      issuedAt: now
    )
  }

  private func isFinalizing(
    snapshot: VoiceInputSnapshot,
    now: Date
  ) -> Bool {
    snapshot.phase == .transcribing
      && snapshot.sessionID != nil
      && hasCurrentHeartbeat(snapshot.heartbeatAt, now: now)
  }

  private func hasCurrentHeartbeat(_ heartbeatAt: Date?, now: Date) -> Bool {
    guard let heartbeatAt else {
      return false
    }
    let age = now.timeIntervalSince(heartbeatAt)
    return age >= 0 && age <= staleAfter
  }
}

public struct VoiceInputSystemCaptureCommandHandler: Equatable, Sendable {
  private let policy: VoiceInputSystemCapturePolicy

  public init(policy: VoiceInputSystemCapturePolicy = VoiceInputSystemCapturePolicy()) {
    self.policy = policy
  }

  public func setRecording(
    _ requestedRecording: Bool,
    store: any VoiceInputStateStoring,
    requestedSessionID: UUID = UUID(),
    styleKind: VoiceInputStyleKind = .natural,
    now: Date = .now
  ) throws -> VoiceInputSystemCaptureCommandOutcome {
    let snapshot = try store.readSnapshot()
    guard
      let command = policy.command(
        settingRecording: requestedRecording,
        snapshot: snapshot,
        requestedSessionID: requestedSessionID,
        styleKind: styleKind,
        now: now
      )
    else {
      return .unchanged
    }
    try store.writeCommand(command)
    switch command.kind {
    case .start:
      return .queuedStart(sessionID: command.sessionID)
    case .stop:
      return .queuedStop(sessionID: command.sessionID)
    }
  }
}
