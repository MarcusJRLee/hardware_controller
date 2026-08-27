import Foundation

public struct VoiceInputSnapshot: Codable, Equatable, Sendable {
  public static let schemaRevision = 1

  public enum Phase: String, Codable, Equatable, Hashable, Sendable {
    case idle
    case recording
    case transcribing
    case ready
    case interrupted
    case failed
  }

  public let schemaRevision: Int
  public let phase: Phase
  public let sessionID: UUID?
  public let sequence: UInt64
  public let heartbeatAt: Date?
  public let text: String?

  public init(
    schemaRevision: Int = Self.schemaRevision,
    phase: Phase,
    sessionID: UUID?,
    sequence: UInt64,
    heartbeatAt: Date?,
    text: String?
  ) {
    self.schemaRevision = schemaRevision
    self.phase = phase
    self.sessionID = sessionID
    self.sequence = sequence
    self.heartbeatAt = heartbeatAt
    self.text = text
  }

  public static func idle(sequence: UInt64) -> VoiceInputSnapshot {
    VoiceInputSnapshot(
      phase: .idle,
      sessionID: nil,
      sequence: sequence,
      heartbeatAt: nil,
      text: nil
    )
  }

  public static func recording(
    sessionID: UUID,
    sequence: UInt64,
    heartbeatAt: Date
  ) -> VoiceInputSnapshot {
    VoiceInputSnapshot(
      phase: .recording,
      sessionID: sessionID,
      sequence: sequence,
      heartbeatAt: heartbeatAt,
      text: nil
    )
  }

  public static func ready(
    sessionID: UUID,
    sequence: UInt64,
    text: String
  ) -> VoiceInputSnapshot {
    VoiceInputSnapshot(
      phase: .ready,
      sessionID: sessionID,
      sequence: sequence,
      heartbeatAt: nil,
      text: text
    )
  }
}

public enum VoiceInputKeyboardDecision: Equatable, Sendable {
  case requiresFullAccess
  case manualActivationRequired
  case requestStop(sessionID: UUID)
  case waitingForResult
  case serviceStale
  case insert(sessionID: UUID, sequence: UInt64, text: String)
  case alreadyInserted
}

public struct VoiceInputInsertionReceipt: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let sequence: UInt64

  public init(sessionID: UUID, sequence: UInt64) {
    self.sessionID = sessionID
    self.sequence = sequence
  }
}

public struct VoiceInputKeyboardPolicy: Equatable, Sendable {
  public let staleAfter: TimeInterval

  public init(staleAfter: TimeInterval = 3) {
    self.staleAfter = staleAfter
  }

  public func microphoneDecision(
    snapshot: VoiceInputSnapshot,
    hasFullAccess: Bool,
    lastInsertionReceipt: VoiceInputInsertionReceipt?,
    now: Date
  ) -> VoiceInputKeyboardDecision {
    guard hasFullAccess else {
      return .requiresFullAccess
    }
    guard snapshot.schemaRevision == VoiceInputSnapshot.schemaRevision else {
      return .serviceStale
    }
    switch snapshot.phase {
    case .idle, .interrupted, .failed:
      return .manualActivationRequired
    case .recording:
      guard
        let sessionID = snapshot.sessionID,
        let heartbeatAt = snapshot.heartbeatAt,
        now.timeIntervalSince(heartbeatAt) >= 0,
        now.timeIntervalSince(heartbeatAt) <= staleAfter
      else {
        return .serviceStale
      }
      return .requestStop(sessionID: sessionID)
    case .transcribing:
      guard snapshot.sessionID != nil else {
        return .serviceStale
      }
      return .waitingForResult
    case .ready:
      guard
        let sessionID = snapshot.sessionID,
        let text = snapshot.text,
        !text.isEmpty
      else {
        return .serviceStale
      }
      if let lastInsertionReceipt,
        lastInsertionReceipt.sessionID == sessionID,
        lastInsertionReceipt.sequence >= snapshot.sequence
      {
        return .alreadyInserted
      }
      return .insert(
        sessionID: sessionID,
        sequence: snapshot.sequence,
        text: text
      )
    }
  }
}
