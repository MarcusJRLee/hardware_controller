import Testing

@testable import HardwareControllerCore
@testable import HardwareControllerMac

struct AppleLocalAIRefinerTest {
  @Test
  func outputBudgetIsBoundedAndScalesWithInput() {
    #expect(AppleFoundationModelRefiner.maximumTokens(for: "a") == 128)
    #expect(
      AppleFoundationModelRefiner.maximumTokens(
        for: String(repeating: "a", count: 1_000)
      ) == 628
    )
    #expect(
      AppleFoundationModelRefiner.maximumTokens(
        for: String(repeating: "a", count: 10_000)
      ) == 2_048
    )
  }

  @Test
  func appleParagraphItemsBecomeIndependentTypedBlocks() throws {
    let output = try AppleFoundationModelDraftAdapter().draft(
      kind: "paragraph",
      items: ["Hi Alex,", "Thanks for the update.", "Best, Jamie"]
    )

    #expect(
      output.blocks.map(\.kind) == [
        .paragraph,
        .paragraph,
        .paragraph,
      ])
    #expect(
      output.blocks.map(\.items) == [
        ["Hi Alex,"],
        ["Thanks for the update."],
        ["Best, Jamie"],
      ])
  }
}
