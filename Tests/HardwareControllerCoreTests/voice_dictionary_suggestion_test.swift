import Testing

@testable import HardwareControllerCore

struct VoiceDictionarySuggestionTest {
  private func suggest(
    _ original: String,
    _ corrected: String,
    dictionary: PersonalDictionary = .empty
  ) -> [VoiceDictionarySuggestion] {
    VoiceDictionarySuggester.suggestions(
      original: original,
      corrected: corrected,
      dictionary: dictionary
    )
  }

  @Test
  func misheardNameBecomesAVocabularyHintOnly() {
    #expect(
      suggest("Ask Kit about the capuchin build.", "Ask Kit about the Cappuccino build.")
        == [.vocabulary("Cappuccino")]
    )
  }

  @Test
  func multiwordMishearingAlsoOffersALiteralReplacement() {
    #expect(
      suggest("Run open code on this branch", "Run OpenCode on this branch")
        == [
          .vocabulary("OpenCode"),
          .replacement(spokenForm: "open code", replacement: "OpenCode"),
        ]
    )
    #expect(
      suggest("Install the contact seven MCP server", "Install the Context7 MCP server")
        == [
          .vocabulary("Context7"),
          .replacement(spokenForm: "contact seven", replacement: "Context7"),
        ]
    )
  }

  @Test(arguments: [
    ("Send it to their office.", "Send it to there office."),
    ("Ship the build today.", "ship the build today"),
    ("Ship the build today.", "Ship the build"),
    ("Ship the build today.", "Ship the new build today."),
    ("Merge the branch.", "Merge the branches."),
    ("Ship it now please.", "Cancel everything and wait for Alex."),
    ("", "OpenCode"),
  ])
  func ordinaryRewriteDeletionInsertionAndCaseEditsSuggestNothing(
    original: String,
    corrected: String
  ) {
    #expect(suggest(original, corrected).isEmpty)
  }

  @Test
  func existingEntriesAreNotSuggestedAgainAndTheListStaysShort() {
    let dictionary = PersonalDictionary(
      vocabulary: ["opencode"],
      replacements: [
        PersonalDictionaryReplacement(spokenForm: "Open Code", replacement: "OpenCode")
      ]
    )
    #expect(suggest("Run open code now", "Run OpenCode now", dictionary: dictionary).isEmpty)
    #expect(
      suggest(
        "alpha one beta two gamma three delta four echo five foxtrot six golf seven",
        "Alpha1 one Beta2 two Gamma3 three delta four echo five foxtrot six golf seven"
      ).count == VoiceDictionarySuggester.maximumSuggestions
    )
  }

  @Test
  func applyingIsIdempotentAndCaseInsensitive() {
    let once = VoiceDictionarySuggester.applying(.vocabulary("OpenCode"), to: .empty)
    let twice = VoiceDictionarySuggester.applying(.vocabulary("opencode"), to: once)
    #expect(twice.vocabulary == ["OpenCode"])

    let replacement = VoiceDictionarySuggestion.replacement(
      spokenForm: "open code",
      replacement: "OpenCode"
    )
    let added = VoiceDictionarySuggester.applying(replacement, to: twice)
    let repeated = VoiceDictionarySuggester.applying(replacement, to: added)
    #expect(repeated.replacements.map(\.spokenForm) == ["open code"])
    #expect(repeated.replacements.map(\.replacement) == ["OpenCode"])
  }
}
