import Testing

@testable import HardwareControllerCore

struct DictionaryReplacementPatternTests {
  @Test
  func invalidPatternsAreRejected() {
    let cases: [(PersonalDictionaryReplacement, DictionaryReplacementPatternError)] = [
      (entry("{number}", "#{number}"), .spokenFormNeedsWords),
      (entry("PR {number} {number}", "PR"), .repeatedSlot(.number)),
      (entry("PR", "PR {number}"), .slotMissingFromSpokenForm(.number)),
    ]

    for (invalid, error) in cases {
      #expect(throws: error) { try invalid.validatePattern() }
      #expect(!invalid.hasValidPattern)
    }
  }

  @Test
  func outputsReportRenderedSlotTextForProtection() {
    let dictionary = PersonalDictionary(
      replacements: [entry("PR {number}", "PR {number}"), entry("hc", "Hardware Controller")]
    )

    #expect(
      dictionary.replacementOutputs(in: "Ship PR 44, then pr 7.")
        == ["PR 44", "pr 7", "Hardware Controller"]
    )
    #expect(entry("PR {number}", "PR {number}").replacementTerm == "PR")
  }
}
