import Foundation

public struct VoiceInputCommand: Codable, Equatable, Sendable {
  public static let schemaRevision = 1

  public enum Kind: String, Codable, Equatable, Sendable {
    case start
    case stop
  }

  public let schemaRevision: Int
  public let kind: Kind
  public let sessionID: UUID
  public let issuedAt: Date

  public static func stop(sessionID: UUID, issuedAt: Date) -> VoiceInputCommand {
    VoiceInputCommand(
      schemaRevision: schemaRevision,
      kind: .stop,
      sessionID: sessionID,
      issuedAt: issuedAt
    )
  }

  public static func start(sessionID: UUID, issuedAt: Date) -> VoiceInputCommand {
    VoiceInputCommand(
      schemaRevision: schemaRevision,
      kind: .start,
      sessionID: sessionID,
      issuedAt: issuedAt
    )
  }
}

public struct VoiceInputCommandPolicy: Equatable, Sendable {
  public let maximumAge: TimeInterval

  public init(maximumAge: TimeInterval = 30) {
    self.maximumAge = maximumAge
  }

  public func accepts(_ command: VoiceInputCommand, now: Date) -> Bool {
    let age = now.timeIntervalSince(command.issuedAt)
    return command.schemaRevision == VoiceInputCommand.schemaRevision
      && age >= 0
      && age <= maximumAge
  }
}

public enum VoiceInputStoreError: Error, Equatable, Sendable {
  case invalidSnapshot
  case invalidCommand
  case invalidKeyboardPresence
  case commandPending
  case recordTooLarge(limit: Int)
  case keychain(status: Int32)
}

public protocol VoiceInputStateStoring: Sendable {
  func readSnapshot() throws -> VoiceInputSnapshot
  func writeSnapshot(_ snapshot: VoiceInputSnapshot) throws
  func readCommand() throws -> VoiceInputCommand?
  func writeCommand(_ command: VoiceInputCommand) throws
  func consumeCommand() throws -> VoiceInputCommand?
}

enum VoiceInputJSON {
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
