import Foundation

public struct PersonalDictionaryReplacement:
  Codable,
  Equatable,
  Identifiable,
  Sendable
{
  public let id: UUID
  public var spokenForm: String
  public var replacement: String

  public init(
    id: UUID = UUID(),
    spokenForm: String,
    replacement: String
  ) {
    self.id = id
    self.spokenForm = spokenForm
    self.replacement = replacement
  }
}

public struct PersonalDictionary: Codable, Equatable, Sendable {
  public var vocabulary: [String]
  public var replacements: [PersonalDictionaryReplacement]

  public init(
    vocabulary: [String] = [],
    replacements: [PersonalDictionaryReplacement] = []
  ) {
    self.vocabulary = vocabulary
    self.replacements = replacements
  }

  public static let empty = PersonalDictionary()
}
