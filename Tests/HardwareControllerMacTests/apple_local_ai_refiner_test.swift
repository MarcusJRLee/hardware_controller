import Testing

@testable import HardwareControllerCore
@testable import HardwareControllerMac

struct AppleLocalAIRefinerTest {
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
