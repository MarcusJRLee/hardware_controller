import Testing

@testable import HardwareControllerCore

struct PersonalDictionaryReplacementApplierTests {
  private let pullRequest = entry("PR {number}", "PR {number}")

  @Test(
    arguments: [
      ("Review P R forty-four today.", "Review PR 44 today."),
      ("Review p.r. forty four.", "Review PR 44."),
      ("Review PR 44 and P R one two three.", "Review PR 44 and PR 123."),
      ("See P R forty four and issue ten.", "See PR 44 and issue ten."),
      ("See P R one hundred and two.", "See PR 102."),
      ("Merge the PR.", "Merge the PR."),
      ("Merge the P R.", "Merge the P R."),
      ("The prone forty four stays.", "The prone forty four stays."),
      ("Forty four stays unchanged.", "Forty four stays unchanged."),
    ]
  )
  func numberSlotRendersDigitsOnlyBesideItsWords(
    transcript: String,
    expected: String
  ) {
    #expect(apply([pullRequest], to: transcript) == expected)
  }

  @Test
  func slotBeforeWordsNeedsTheWholeSpanToBeANumber() {
    let percent = entry("{number} percent", "{number}%")

    #expect(apply([percent], to: "Up twenty five percent.") == "Up 25%.")
    #expect(apply([percent], to: "Up and percent.") == "Up and percent.")
  }

  @Test
  func exactReplacementsUseCaseInsensitiveWordBoundaries() {
    let dictionary = [
      entry("whisper flow", "Wispr Flow"),
      entry("TSC", "TypeScript compiler"),
    ]

    #expect(
      apply(dictionary, to: "WHISPER FLOW uses t s c, not itscored.")
        == "Wispr Flow uses TypeScript compiler, not itscored."
    )
  }

  @Test
  func equalLengthOverlappingReplacementsUseConfiguredOrder() {
    let dictionary = [entry("alpha beta", "X"), entry("beta gamma", "Y")]

    #expect(apply(dictionary, to: "alpha beta gamma") == "X gamma")
  }

  @Test
  func diacriticsFoldOnlyWhenOffsetsAreStable() {
    let dictionary = [entry("cafe", "Café Nero")]

    #expect(apply(dictionary, to: "Meet at café.") == "Meet at Café Nero.")
  }

  @Test
  func invalidPatternsAreNeverApplied() {
    #expect(
      apply([entry("PR", "PR {number}")], to: "PR forty four")
        == "PR forty four"
    )
  }

  private func apply(
    _ replacements: [PersonalDictionaryReplacement],
    to transcript: String
  ) -> String {
    PersonalDictionaryReplacementApplier().apply(
      PersonalDictionary(replacements: replacements),
      to: transcript
    )
  }
}

func entry(
  _ spokenForm: String,
  _ replacement: String
) -> PersonalDictionaryReplacement {
  PersonalDictionaryReplacement(spokenForm: spokenForm, replacement: replacement)
}
