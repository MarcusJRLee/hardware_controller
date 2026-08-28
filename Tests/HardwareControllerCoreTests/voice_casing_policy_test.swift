import Testing

@testable import HardwareControllerCore

struct VoiceCasingPolicyTest {
  @Test
  func lowercaseInstructionResolvesToStrictPolicy() {
    var settings = LocalAISettings.default
    settings.additionalInstructions = "only provide text in lowercase"

    #expect(settings.effectiveCasingPolicy == .strictLowercase)
  }

  @Test
  func strictLowercaseProtectsIntentionalTokens() {
    let text =
      "Send NASA status to Ops@Example.com from /Users/Demo/Input and call parseJSON."

    let result = VoiceCasingTransformer().apply(
      .strictLowercase,
      to: text,
      preserving: text,
      dictionary: .empty
    )

    #expect(
      result
        == "send nasa status to Ops@Example.com from /Users/Demo/Input and call parseJSON."
    )
  }

  @Test
  func lowercaseProsePreservesSourceNamesAndAcronyms() {
    let text = "Meet Sarah from NASA and call parseJSON."

    let result = VoiceCasingTransformer().apply(
      .lowercaseProse,
      to: text,
      preserving: text,
      dictionary: .empty
    )

    #expect(result == "meet Sarah from NASA and call parseJSON.")
  }
}
