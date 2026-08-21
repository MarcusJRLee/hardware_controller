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
}
