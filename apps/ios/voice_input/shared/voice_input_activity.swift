import ActivityKit
import Foundation

public struct VoiceInputActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable, Sendable {
    public let phase: VoiceInputSnapshot.Phase

    public init(phase: VoiceInputSnapshot.Phase) {
      self.phase = phase
    }
  }

  public let sessionID: UUID

  public init(sessionID: UUID) {
    self.sessionID = sessionID
  }
}
