import HardwareControllerCore
import Testing

struct TranscriptCompositionTests {
  @Test
  func provisionalRevisionReplacesOnlyTheOwnedSuffix() throws {
    var composition = TranscriptComposition()

    let first = try composition.apply(
      .provisional("hard ware")
    )
    let corrected = try composition.apply(
      .provisional("hardware controller")
    )

    #expect(
      first
        == TranscriptCompositionMutation(
          expectedCaretOffset: 0,
          replacementOffset: 0,
          replacementLength: 0,
          replacementText: "hard ware"
        )
    )
    #expect(
      corrected
        == TranscriptCompositionMutation(
          expectedCaretOffset: 9,
          replacementOffset: 0,
          replacementLength: 9,
          replacementText: "hardware controller"
        )
    )
  }

  @Test
  func finalizedPrefixIsNeverSelectedAgain() throws {
    var composition = TranscriptComposition()
    _ = try composition.apply(.provisional("hello"))
    _ = try composition.apply(.committed("Hello"))
    let next = try composition.apply(
      .provisional("wor", committedText: "Hello")
    )
    let corrected = try composition.apply(
      .provisional("world", committedText: "Hello")
    )

    #expect(
      next
        == TranscriptCompositionMutation(
          expectedCaretOffset: 5,
          replacementOffset: 5,
          replacementLength: 0,
          replacementText: " wor"
        )
    )
    #expect(
      corrected
        == TranscriptCompositionMutation(
          expectedCaretOffset: 9,
          replacementOffset: 5,
          replacementLength: 4,
          replacementText: " world"
        )
    )
  }

  @Test
  func unchangedRenderedTextAdvancesTheCommittedPrefix()
    throws
  {
    var composition = TranscriptComposition()
    _ = try composition.apply(.provisional("Hello world"))

    let mutation = try composition.apply(
      .committed("Hello world")
    )
    let next = try composition.apply(
      .provisional(
        "again",
        committedText: "Hello world"
      )
    )

    #expect(mutation == nil)
    #expect(
      next?.replacementOffset
        == "Hello world".utf16.count
    )
    #expect(next?.replacementText == " again")
  }

  @Test
  func committedTextCannotBeRevised() throws {
    var composition = TranscriptComposition()
    _ = try composition.apply(.committed("Hardware"))

    #expect(
      throws: TranscriptCompositionFailure.committedTextChanged
    ) {
      try composition.apply(.committed("Software"))
    }
  }

  @Test
  func cancelRemovesOnlyTheProvisionalSuffix() throws {
    var composition = TranscriptComposition()
    _ = try composition.apply(
      .provisional(
        "temporary",
        committedText: "Keep this"
      )
    )

    let mutation = composition.cancel()

    #expect(
      mutation
        == TranscriptCompositionMutation(
          expectedCaretOffset: 19,
          replacementOffset: 9,
          replacementLength: 10,
          replacementText: ""
        )
    )
    #expect(composition.revision == .committed("Keep this"))
  }

  @Test
  func accessibilityOffsetsUseUTF16Units() throws {
    var composition = TranscriptComposition()

    let mutation = try composition.apply(
      .provisional("👍🏽")
    )

    #expect(mutation?.replacementText == "👍🏽")
    #expect(
      try composition.apply(.provisional("👍🏽 ok"))?
        .expectedCaretOffset == "👍🏽".utf16.count
    )
  }
}
