import Foundation

public enum LocalAIProviderKind: String, CaseIterable, Codable, Sendable {
  case appleOnDevice
  case ollama
}

/// Declares the furthest boundary a provider can cross with Voice content.
public enum LocalAIProviderLocality: Equatable, Sendable {
  case inProcess
  case fixedLoopback
  case remoteCapable

  public var permitsContentInLocalOnlyMode: Bool {
    switch self {
    case .inProcess, .fixedLoopback:
      true
    case .remoteCapable:
      false
    }
  }
}

/// Makes provider identity and locality mandatory at the adapter boundary.
public struct LocalAIProviderCapability: Equatable, Sendable {
  public let provider: LocalAIProviderKind
  public let locality: LocalAIProviderLocality

  public init(
    provider: LocalAIProviderKind,
    locality: LocalAIProviderLocality
  ) {
    self.provider = provider
    self.locality = locality
  }
}

public enum LocalAIModelRetention: String, CaseIterable, Codable, Sendable {
  case recentUse
  case processLifetime
}

public struct LocalAIModelSelection: Codable, Equatable, Sendable {
  public var name: String
  public var expectedDigest: String?

  public init(name: String, expectedDigest: String? = nil) {
    self.name = name
    self.expectedDigest = expectedDigest
  }
}

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

public struct LocalAISettings: Codable, Equatable, Sendable {
  public static let defaultRecommendedModelName = "qwen3.5:4b"

  public var provider: LocalAIProviderKind
  public var ollamaModel: LocalAIModelSelection
  public var modelRetention: LocalAIModelRetention
  public var includeNearbyText: Bool
  public var dictionary: PersonalDictionary
  public var additionalInstructions: String
  public var style: VoiceStyle

  public init(
    provider: LocalAIProviderKind = .appleOnDevice,
    ollamaModel: LocalAIModelSelection = LocalAIModelSelection(
      name: defaultRecommendedModelName
    ),
    modelRetention: LocalAIModelRetention = .recentUse,
    includeNearbyText: Bool = false,
    dictionary: PersonalDictionary = .empty,
    additionalInstructions: String = "",
    style: VoiceStyle = .natural
  ) {
    self.provider = provider
    self.ollamaModel = ollamaModel
    self.modelRetention = modelRetention
    self.includeNearbyText = includeNearbyText
    self.dictionary = dictionary
    self.additionalInstructions = additionalInstructions
    self.style = style
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case ollamaModel
    case modelRetention
    case includeNearbyText
    case dictionary
    case additionalInstructions
    case style
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(LocalAIProviderKind.self, forKey: .provider)
    ollamaModel = try container.decode(
      LocalAIModelSelection.self,
      forKey: .ollamaModel
    )
    modelRetention = try container.decode(
      LocalAIModelRetention.self,
      forKey: .modelRetention
    )
    includeNearbyText = try container.decode(Bool.self, forKey: .includeNearbyText)
    dictionary = try container.decode(PersonalDictionary.self, forKey: .dictionary)
    additionalInstructions = try container.decode(
      String.self,
      forKey: .additionalInstructions
    )
    style = try container.decodeIfPresent(VoiceStyle.self, forKey: .style) ?? .natural
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(provider, forKey: .provider)
    try container.encode(ollamaModel, forKey: .ollamaModel)
    try container.encode(modelRetention, forKey: .modelRetention)
    try container.encode(includeNearbyText, forKey: .includeNearbyText)
    try container.encode(dictionary, forKey: .dictionary)
    try container.encode(additionalInstructions, forKey: .additionalInstructions)
    try container.encode(style, forKey: .style)
  }

  public static let `default` = LocalAISettings()
}

public enum LocalAISettingsValidationError: Error, Equatable, Sendable {
  case emptyModelName
  case emptyExpectedDigest
  case tooManyVocabularyEntries
  case invalidVocabularyEntry
  case duplicateVocabularyEntry
  case tooManyReplacements
  case invalidReplacement
  case duplicateSpokenForm
  case instructionsTooLong
  case unsupportedStyleRevision(Int)
}

extension LocalAISettings {
  public func validate() throws {
    guard style.revision == VoiceStyle.currentRevision else {
      throw LocalAISettingsValidationError.unsupportedStyleRevision(
        style.revision
      )
    }
    guard !ollamaModel.name.normalizedLocalAIValue.isEmpty else {
      throw LocalAISettingsValidationError.emptyModelName
    }
    if let expectedDigest = ollamaModel.expectedDigest {
      guard !expectedDigest.normalizedLocalAIValue.isEmpty else {
        throw LocalAISettingsValidationError.emptyExpectedDigest
      }
    }
    guard dictionary.vocabulary.count <= 200 else {
      throw LocalAISettingsValidationError.tooManyVocabularyEntries
    }
    var vocabulary: Set<String> = []
    for entry in dictionary.vocabulary {
      let normalized = entry.normalizedLocalAIValue
      guard !normalized.isEmpty, normalized.count <= 100 else {
        throw LocalAISettingsValidationError.invalidVocabularyEntry
      }
      guard vocabulary.insert(normalized.lowercased()).inserted else {
        throw LocalAISettingsValidationError.duplicateVocabularyEntry
      }
    }
    guard dictionary.replacements.count <= 200 else {
      throw LocalAISettingsValidationError.tooManyReplacements
    }
    var spokenForms: Set<String> = []
    for replacement in dictionary.replacements {
      let spokenForm = replacement.spokenForm.normalizedLocalAIValue
      let output = replacement.replacement.normalizedLocalAIValue
      guard
        !spokenForm.isEmpty,
        !output.isEmpty,
        spokenForm.count <= 100,
        output.count <= 100
      else {
        throw LocalAISettingsValidationError.invalidReplacement
      }
      guard spokenForms.insert(spokenForm.lowercased()).inserted else {
        throw LocalAISettingsValidationError.duplicateSpokenForm
      }
    }
    guard additionalInstructions.count <= 2_000 else {
      throw LocalAISettingsValidationError.instructionsTooLong
    }
  }
}

public struct LocalAITargetContext: Equatable, Sendable {
  public let localeIdentifier: String
  public let profileName: String
  public let applicationName: String
  public let applicationBundleIdentifier: String?
  public let targetRole: String?
  public let supportsMultilineText: Bool
  public let nearbyText: String?

  public init(
    localeIdentifier: String,
    profileName: String,
    applicationName: String,
    applicationBundleIdentifier: String?,
    targetRole: String?,
    supportsMultilineText: Bool,
    nearbyText: String?
  ) {
    self.localeIdentifier = localeIdentifier
    self.profileName = profileName
    self.applicationName = applicationName
    self.applicationBundleIdentifier = applicationBundleIdentifier
    self.targetRole = targetRole
    self.supportsMultilineText = supportsMultilineText
    self.nearbyText = nearbyText
  }
}

public struct LocalAIRefinementRequest: Equatable, Sendable {
  public let sessionID: UUID
  public let transcript: String
  public let context: LocalAITargetContext
  public let dictionary: PersonalDictionary
  public let additionalInstructions: String
  public let style: VoiceStyle

  public init(
    sessionID: UUID,
    transcript: String,
    context: LocalAITargetContext,
    dictionary: PersonalDictionary,
    additionalInstructions: String,
    style: VoiceStyle = .natural
  ) {
    self.sessionID = sessionID
    self.transcript = transcript
    self.context = context
    self.dictionary = dictionary
    self.additionalInstructions = additionalInstructions
    self.style = style
  }
}

public struct LocalAIRefinementResponse: Equatable, Sendable {
  public let text: String
  public let provider: LocalAIProviderKind
  public let modelIdentifier: String
  public let modelLoadNanoseconds: UInt64?
  public let generationNanoseconds: UInt64?
  public let generatedTokenCount: Int?
  public let tokenGenerationNanoseconds: UInt64?

  public init(
    text: String,
    provider: LocalAIProviderKind,
    modelIdentifier: String,
    modelLoadNanoseconds: UInt64? = nil,
    generationNanoseconds: UInt64? = nil,
    generatedTokenCount: Int? = nil,
    tokenGenerationNanoseconds: UInt64? = nil
  ) {
    self.text = text
    self.provider = provider
    self.modelIdentifier = modelIdentifier
    self.modelLoadNanoseconds = modelLoadNanoseconds
    self.generationNanoseconds = generationNanoseconds
    self.generatedTokenCount = generatedTokenCount
    self.tokenGenerationNanoseconds = tokenGenerationNanoseconds
  }
}

public enum LocalAIRefinementFailure: Error, Equatable, Sendable {
  case providerUnavailable(String)
  case remoteProviderRejected
  case modelMissing(String)
  case modelDigestChanged(expected: String, actual: String)
  case timedOut
  case invalidResponse(String)
  case requestTooLarge
  case generationFailed(String)
}

public struct LocalAIInstalledModel: Equatable, Identifiable, Sendable {
  public var id: String { name }
  public let name: String
  public let digest: String
  public let sizeBytes: UInt64
  public let isValidated: Bool
  public let isRecommended: Bool

  public init(
    name: String,
    digest: String,
    sizeBytes: UInt64,
    isValidated: Bool,
    isRecommended: Bool
  ) {
    self.name = name
    self.digest = digest
    self.sizeBytes = sizeBytes
    self.isValidated = isValidated
    self.isRecommended = isRecommended
  }
}

public enum LocalAIReadinessState: Equatable, Sendable {
  case checking
  case ready
  case unavailable(String)
  case modelMissing(String)
  case modelDigestChanged(expected: String, actual: String)

  public var canRun: Bool {
    self == .ready
  }
}

public struct LocalAIProviderReadiness: Equatable, Sendable {
  public let provider: LocalAIProviderKind
  public let state: LocalAIReadinessState
  public let models: [LocalAIInstalledModel]

  public init(
    provider: LocalAIProviderKind,
    state: LocalAIReadinessState,
    models: [LocalAIInstalledModel] = []
  ) {
    self.provider = provider
    self.state = state
    self.models = models
  }
}

public struct LocalAIReadinessSnapshot: Equatable, Sendable {
  public let apple: LocalAIProviderReadiness
  public let ollama: LocalAIProviderReadiness

  public init(
    apple: LocalAIProviderReadiness,
    ollama: LocalAIProviderReadiness
  ) {
    self.apple = apple
    self.ollama = ollama
  }

  public static let checking = LocalAIReadinessSnapshot(
    apple: LocalAIProviderReadiness(
      provider: .appleOnDevice,
      state: .checking
    ),
    ollama: LocalAIProviderReadiness(
      provider: .ollama,
      state: .checking
    )
  )

  public func readiness(
    for provider: LocalAIProviderKind
  ) -> LocalAIProviderReadiness {
    provider == .appleOnDevice ? apple : ollama
  }
}

public enum LocalAIProviderTestState: Equatable, Sendable {
  case idle
  case running
  case passed
  case failed(LocalAIRefinementFailure)
}

public enum LocalAIDictationPhase: String, Equatable, Sendable {
  case idle
  case preparing
  case listening
  case finalizing
  case refining
  case validating
  case delivering
  case canceling
  case completed
  case failed
}

public enum LocalAIDictationFailure: Error, Equatable, Sendable {
  case transcription(TranscriptionFailure)
  case refinement(LocalAIRefinementFailure)
  case delivery(TranscriptionFailure)
}

public struct LocalAIDictationSnapshot: Equatable, Sendable {
  public let sessionID: UUID?
  public let phase: LocalAIDictationPhase
  public let volatileText: String
  public let rawText: String
  public let refinedText: String
  public let targetApplicationName: String?
  public let failure: LocalAIDictationFailure?
  public let fallbackReason: LocalAIRefinementFailure?
  public let refinementNanoseconds: UInt64?

  public init(
    sessionID: UUID?,
    phase: LocalAIDictationPhase,
    volatileText: String,
    rawText: String,
    refinedText: String,
    targetApplicationName: String?,
    failure: LocalAIDictationFailure?,
    fallbackReason: LocalAIRefinementFailure? = nil,
    refinementNanoseconds: UInt64? = nil
  ) {
    self.sessionID = sessionID
    self.phase = phase
    self.volatileText = volatileText
    self.rawText = rawText
    self.refinedText = refinedText
    self.targetApplicationName = targetApplicationName
    self.failure = failure
    self.fallbackReason = fallbackReason
    self.refinementNanoseconds = refinementNanoseconds
  }

  public static let idle = LocalAIDictationSnapshot(
    sessionID: nil,
    phase: .idle,
    volatileText: "",
    rawText: "",
    refinedText: "",
    targetApplicationName: nil,
    failure: nil
  )

  public var hasRecoverableRawText: Bool {
    !rawText.isEmpty
  }

  public var hasRecoverableRefinedText: Bool {
    !refinedText.isEmpty
  }
}

extension String {
  fileprivate var normalizedLocalAIValue: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
