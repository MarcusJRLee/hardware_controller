import ActivityKit
import Foundation

public struct VoiceProbeActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable, Sendable {
    public let phase: VoiceProbeSnapshot.Phase

    public init(phase: VoiceProbeSnapshot.Phase) {
      self.phase = phase
    }
  }

  public let sessionID: UUID

  public init(sessionID: UUID) {
    self.sessionID = sessionID
  }
}
