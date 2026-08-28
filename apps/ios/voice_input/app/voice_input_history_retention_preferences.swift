import Foundation
import HardwareControllerVoiceCore

enum VoiceInputHistoryRetentionPreferenceError:
  Error,
  Equatable,
  LocalizedError
{
  case invalidData
  case invalidSettings
  case unsupportedSchema

  var errorDescription: String? {
    switch self {
    case .invalidData:
      "Voice History storage settings are damaged."
    case .invalidSettings:
      "Voice History storage settings are outside supported limits."
    case .unsupportedSchema:
      "Voice History storage settings require a newer app."
    }
  }
}

@MainActor
protocol VoiceInputHistoryRetentionPreferenceStoring: AnyObject {
  func read() throws -> VoiceHistoryRetentionSettings
  func write(_ settings: VoiceHistoryRetentionSettings) throws
}

@MainActor
final class VoiceInputHistoryRetentionPreferenceStore:
  VoiceInputHistoryRetentionPreferenceStoring
{
  static let standardKey = "voice_input_history_retention"

  private let defaults: UserDefaults
  private let key: String

  init(
    defaults: UserDefaults = .standard,
    key: String = VoiceInputHistoryRetentionPreferenceStore.standardKey
  ) {
    self.defaults = defaults
    self.key = key
  }

  func read() throws -> VoiceHistoryRetentionSettings {
    guard let data = defaults.data(forKey: key) else {
      return .iOSDefault
    }
    let envelope: Envelope
    do {
      envelope = try JSONDecoder().decode(Envelope.self, from: data)
    } catch {
      throw VoiceInputHistoryRetentionPreferenceError.invalidData
    }
    guard envelope.schemaRevision == Envelope.currentSchemaRevision else {
      throw VoiceInputHistoryRetentionPreferenceError.unsupportedSchema
    }
    do {
      return try envelope.settings.validated()
    } catch {
      throw VoiceInputHistoryRetentionPreferenceError.invalidSettings
    }
  }

  func write(_ settings: VoiceHistoryRetentionSettings) throws {
    let validated: VoiceHistoryRetentionSettings
    do {
      validated = try settings.validated()
    } catch {
      throw VoiceInputHistoryRetentionPreferenceError.invalidSettings
    }
    let envelope = Envelope(
      schemaRevision: Envelope.currentSchemaRevision,
      settings: validated
    )
    do {
      defaults.set(try JSONEncoder().encode(envelope), forKey: key)
    } catch {
      throw VoiceInputHistoryRetentionPreferenceError.invalidData
    }
  }
}

private struct Envelope: Codable {
  static let currentSchemaRevision = 1

  let schemaRevision: Int
  let settings: VoiceHistoryRetentionSettings
}
