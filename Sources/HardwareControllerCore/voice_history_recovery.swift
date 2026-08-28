import Foundation

public enum VoiceHistoryRecoveryKind:
  String,
  Codable,
  Equatable,
  Sendable
{
  case interruptedCapture = "interrupted_capture"
  case orphanedFinalization = "orphaned_finalization"
  case interruptedExpiration = "interrupted_expiration"
}

public struct VoiceHistoryRecoverySessionDescriptor: Equatable, Sendable {
  public let id: UUID
  public let audioFilename: String?
  public let audioExpirationReason: VoiceHistoryAudioExpirationReason?

  public init(
    id: UUID,
    audioFilename: String?,
    audioExpirationReason: VoiceHistoryAudioExpirationReason?
  ) {
    self.id = id
    self.audioFilename = audioFilename
    self.audioExpirationReason = audioExpirationReason
  }
}

public struct VoiceHistoryRecoveryArtifactDescriptor: Equatable, Sendable {
  public let filename: String
  public let modifiedAt: Date
  public let isReadableAudio: Bool

  public init(
    filename: String,
    modifiedAt: Date,
    isReadableAudio: Bool
  ) {
    self.filename = filename
    self.modifiedAt = modifiedAt
    self.isReadableAudio = isReadableAudio
  }
}

public enum VoiceHistoryRecoveryAction: Equatable, Sendable {
  case discardCommittedQuarantine(filename: String)
  case restoreQuarantine(
    filename: String,
    destinationFilename: String,
    sessionID: UUID
  )
  case recover(
    filename: String,
    preferredSessionID: UUID?,
    kind: VoiceHistoryRecoveryKind
  )
  case removeStaleUnreadable(filename: String)
}

public enum VoiceHistoryRecoveryIssue: Equatable, Sendable {
  case unreadableArtifact(filename: String)
}

public struct VoiceHistoryRecoveryPlan: Equatable, Sendable {
  public let actions: [VoiceHistoryRecoveryAction]
  public let issues: [VoiceHistoryRecoveryIssue]

  public init(
    actions: [VoiceHistoryRecoveryAction],
    issues: [VoiceHistoryRecoveryIssue]
  ) {
    self.actions = actions
    self.issues = issues
  }
}

public enum VoiceHistoryRecoveryPlanner {
  private static let unreadableArtifactLifetime: TimeInterval = 86_400

  public static func plan(
    sessions: [VoiceHistoryRecoverySessionDescriptor],
    artifacts: [VoiceHistoryRecoveryArtifactDescriptor],
    now: Date
  ) -> VoiceHistoryRecoveryPlan {
    let sessionsByID = Dictionary(
      sessions.map { ($0.id, $0) },
      uniquingKeysWith: { existing, _ in existing }
    )
    let referencedFilenames = Set(sessions.compactMap(\.audioFilename))
    var claimedSessionIDs = Set(sessions.map(\.id))
    var plannedActions: [PlannedAction] = []
    var issues: [VoiceHistoryRecoveryIssue] = []

    let ownedArtifacts = artifacts.compactMap { artifact -> OwnedArtifact? in
      guard let name = OwnedArtifactName(filename: artifact.filename) else {
        return nil
      }
      return OwnedArtifact(descriptor: artifact, name: name)
    }

    for artifact in ownedArtifacts.sorted(by: artifactPriority) {
      let filename = artifact.descriptor.filename
      let isReferenced = isReferenced(
        artifact: artifact,
        sessionsByID: sessionsByID,
        filenames: referencedFilenames
      )
      if !artifact.descriptor.isReadableAudio {
        if isReferenced
          || now.timeIntervalSince(artifact.descriptor.modifiedAt)
            <= unreadableArtifactLifetime
        {
          issues.append(.unreadableArtifact(filename: filename))
        } else {
          plannedActions.append(
            PlannedAction(
              rank: .removeStaleUnreadable,
              filename: filename,
              action: .removeStaleUnreadable(filename: filename)
            )
          )
        }
        continue
      }

      switch artifact.name {
      case .final(let sessionID):
        guard !referencedFilenames.contains(filename) else {
          continue
        }
        let preferredID = claim(
          sessionID,
          claimedSessionIDs: &claimedSessionIDs
        )
        plannedActions.append(
          PlannedAction(
            rank: .recoverFinal,
            filename: filename,
            action: .recover(
              filename: filename,
              preferredSessionID: preferredID,
              kind: .orphanedFinalization
            )
          )
        )

      case .partial(let sessionID):
        let preferredID = claim(
          sessionID,
          claimedSessionIDs: &claimedSessionIDs
        )
        plannedActions.append(
          PlannedAction(
            rank: .recoverPartial,
            filename: filename,
            action: .recover(
              filename: filename,
              preferredSessionID: preferredID,
              kind: .interruptedCapture
            )
          )
        )

      case .quarantine(let sessionID, _):
        if let session = sessionsByID[sessionID] {
          if session.audioFilename != nil {
            plannedActions.append(
              PlannedAction(
                rank: .restoreQuarantine,
                filename: filename,
                action: .restoreQuarantine(
                  filename: filename,
                  destinationFilename: "\(sessionID.uuidString).caf",
                  sessionID: sessionID
                )
              )
            )
          } else if session.audioExpirationReason != nil {
            plannedActions.append(
              PlannedAction(
                rank: .discardCommittedQuarantine,
                filename: filename,
                action: .discardCommittedQuarantine(filename: filename)
              )
            )
          }
          continue
        }
        let preferredID = claim(
          sessionID,
          claimedSessionIDs: &claimedSessionIDs
        )
        plannedActions.append(
          PlannedAction(
            rank: .recoverQuarantine,
            filename: filename,
            action: .recover(
              filename: filename,
              preferredSessionID: preferredID,
              kind: .interruptedExpiration
            )
          )
        )
      }
    }

    return VoiceHistoryRecoveryPlan(
      actions: plannedActions.sorted().map(\.action),
      issues: issues.sorted { issueFilename($0) < issueFilename($1) }
    )
  }

  private static func artifactPriority(
    _ lhs: OwnedArtifact,
    _ rhs: OwnedArtifact
  ) -> Bool {
    let lhsPriority = lhs.name.discoveryPriority
    let rhsPriority = rhs.name.discoveryPriority
    if lhsPriority != rhsPriority {
      return lhsPriority < rhsPriority
    }
    return lhs.descriptor.filename < rhs.descriptor.filename
  }

  private static func isReferenced(
    artifact: OwnedArtifact,
    sessionsByID: [UUID: VoiceHistoryRecoverySessionDescriptor],
    filenames: Set<String>
  ) -> Bool {
    if filenames.contains(artifact.descriptor.filename) {
      return true
    }
    guard case .quarantine(let sessionID, _) = artifact.name else {
      return false
    }
    return sessionsByID[sessionID]?.audioFilename != nil
  }

  private static func claim(
    _ sessionID: UUID,
    claimedSessionIDs: inout Set<UUID>
  ) -> UUID? {
    guard claimedSessionIDs.insert(sessionID).inserted else {
      return nil
    }
    return sessionID
  }

  private static func issueFilename(_ issue: VoiceHistoryRecoveryIssue) -> String {
    switch issue {
    case .unreadableArtifact(let filename):
      filename
    }
  }
}

private struct OwnedArtifact {
  let descriptor: VoiceHistoryRecoveryArtifactDescriptor
  let name: OwnedArtifactName
}

private enum OwnedArtifactName {
  case final(sessionID: UUID)
  case partial(sessionID: UUID)
  case quarantine(sessionID: UUID, operationID: UUID)

  init?(filename: String) {
    if filename.hasSuffix(".partial") {
      let identifier = String(filename.dropLast(".partial".count))
      guard let sessionID = UUID(uuidString: identifier) else {
        return nil
      }
      self = .partial(sessionID: sessionID)
      return
    }
    if filename.hasPrefix(".expiring_"), filename.hasSuffix(".caf") {
      let identifiers =
        filename
        .dropFirst(".expiring_".count)
        .dropLast(".caf".count)
        .split(separator: "_", omittingEmptySubsequences: false)
      guard identifiers.count == 2,
        let sessionID = UUID(uuidString: String(identifiers[0])),
        let operationID = UUID(uuidString: String(identifiers[1]))
      else {
        return nil
      }
      self = .quarantine(
        sessionID: sessionID,
        operationID: operationID
      )
      return
    }
    if filename.hasSuffix(".caf") {
      let identifier = String(filename.dropLast(".caf".count))
      guard let sessionID = UUID(uuidString: identifier) else {
        return nil
      }
      self = .final(sessionID: sessionID)
      return
    }
    return nil
  }

  var discoveryPriority: Int {
    switch self {
    case .final:
      0
    case .partial:
      1
    case .quarantine:
      2
    }
  }
}

private struct PlannedAction: Comparable {
  enum Rank: Int {
    case discardCommittedQuarantine
    case restoreQuarantine
    case recoverFinal
    case recoverPartial
    case recoverQuarantine
    case removeStaleUnreadable
  }

  let rank: Rank
  let filename: String
  let action: VoiceHistoryRecoveryAction

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.rank.rawValue != rhs.rank.rawValue {
      return lhs.rank.rawValue < rhs.rank.rawValue
    }
    return lhs.filename < rhs.filename
  }
}
