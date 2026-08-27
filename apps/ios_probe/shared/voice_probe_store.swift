import Foundation

public struct VoiceProbeCommand: Codable, Equatable, Sendable {
  public static let schemaRevision = 1

  public enum Kind: String, Codable, Equatable, Sendable {
    case start
    case stop
  }

  public let schemaRevision: Int
  public let kind: Kind
  public let sessionID: UUID
  public let issuedAt: Date

  public static func stop(sessionID: UUID, issuedAt: Date) -> VoiceProbeCommand {
    VoiceProbeCommand(
      schemaRevision: schemaRevision,
      kind: .stop,
      sessionID: sessionID,
      issuedAt: issuedAt
    )
  }

  public static func start(sessionID: UUID, issuedAt: Date) -> VoiceProbeCommand {
    VoiceProbeCommand(
      schemaRevision: schemaRevision,
      kind: .start,
      sessionID: sessionID,
      issuedAt: issuedAt
    )
  }
}

public struct VoiceProbeCommandPolicy: Equatable, Sendable {
  public let maximumAge: TimeInterval

  public init(maximumAge: TimeInterval = 30) {
    self.maximumAge = maximumAge
  }

  public func accepts(_ command: VoiceProbeCommand, now: Date) -> Bool {
    let age = now.timeIntervalSince(command.issuedAt)
    return command.schemaRevision == VoiceProbeCommand.schemaRevision
      && age >= 0
      && age <= maximumAge
  }
}

public enum VoiceProbeStoreError: Error, Equatable, Sendable {
  case invalidSnapshot
  case invalidCommand
  case commandPending
  case recordTooLarge(limit: Int)
  case keychain(status: Int32)
}

public protocol VoiceProbeStateStoring: Sendable {
  func readSnapshot() throws -> VoiceProbeSnapshot
  func writeSnapshot(_ snapshot: VoiceProbeSnapshot) throws
  func readCommand() throws -> VoiceProbeCommand?
  func writeCommand(_ command: VoiceProbeCommand) throws
  func consumeCommand() throws -> VoiceProbeCommand?
}

enum VoiceProbeJSON {
  static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}
