import Foundation
import Testing

@testable import HardwareControllerCore

struct LocalAIDictationTests {
  @Test
  func defaultSettingsSelectTheRecommendedLocalModel() throws {
    let settings = LocalAISettings.default

    try settings.validate()

    #expect(settings.provider == .appleOnDevice)
    #expect(
      settings.ollamaModel.name
        == LocalAISettings.defaultRecommendedModelName
    )
    #expect(settings.modelRetention == .recentUse)
    #expect(!settings.includeNearbyText)
    #expect(settings.style == .natural)
  }

  @Test
  func legacySettingsDecodeWithNaturalStyle() throws {
    let data = Data(
      """
      {
        "provider":"appleOnDevice",
        "ollamaModel":{"name":"qwen3.5:4b"},
        "modelRetention":"recentUse",
        "includeNearbyText":false,
        "dictionary":{"vocabulary":[],"replacements":[]},
        "additionalInstructions":""
      }
      """.utf8
    )

    let settings = try JSONDecoder().decode(LocalAISettings.self, from: data)

    #expect(settings.style == .natural)
  }

  @Test
  func validatesDictionaryAndInstructionBounds() {
    var settings = LocalAISettings.default
    settings.dictionary = PersonalDictionary(
      vocabulary: ["TSC", "tsc"],
      replacements: []
    )

    #expect(throws: LocalAISettingsValidationError.duplicateVocabularyEntry) {
      try settings.validate()
    }

    settings.dictionary = PersonalDictionary(
      replacements: [
        PersonalDictionaryReplacement(
          spokenForm: "",
          replacement: "TypeScript"
        )
      ]
    )
    #expect(throws: LocalAISettingsValidationError.invalidReplacement) {
      try settings.validate()
    }

    settings.dictionary = .empty
    settings.additionalInstructions = String(repeating: "x", count: 2_001)
    #expect(throws: LocalAISettingsValidationError.instructionsTooLong) {
      try settings.validate()
    }

    settings = .default
    settings.style = VoiceStyle(kind: .formal, revision: 99)
    #expect(
      throws: LocalAISettingsValidationError.unsupportedStyleRevision(99)
    ) {
      try settings.validate()
    }
  }

  @Test
  func snapshotsKeepRawAndRefinedRecoverySeparate() {
    let snapshot = LocalAIDictationSnapshot(
      sessionID: UUID(),
      phase: .completed,
      volatileText: "",
      rawText: "raw words",
      refinedText: "Refined words.",
      targetApplicationName: "Notes",
      failure: nil
    )

    #expect(snapshot.hasRecoverableRawText)
    #expect(snapshot.hasRecoverableRefinedText)
  }

  @Test
  func localOnlyModePermitsOnlyInProcessAndFixedLoopbackProviders() {
    #expect(
      LocalAIProviderLocality.inProcess.permitsContentInLocalOnlyMode
    )
    #expect(
      LocalAIProviderLocality.fixedLoopback.permitsContentInLocalOnlyMode
    )
    #expect(
      !LocalAIProviderLocality.remoteCapable.permitsContentInLocalOnlyMode
    )
  }

  @Test
  func refinementRequestNormalizesListIntent() {
    let request = LocalAIRefinementRequest(
      sessionID: UUID(),
      transcript: "grocery list: apples, bananas, and coffee",
      context: LocalAITargetContext(
        localeIdentifier: "en_US",
        profileName: "Default",
        applicationName: "Notes",
        applicationBundleIdentifier: nil,
        targetRole: nil,
        supportsMultilineText: true,
        nearbyText: nil
      ),
      dictionary: .empty,
      additionalInstructions: ""
    )

    #expect(request.listIntent == .unordered)
  }
}
