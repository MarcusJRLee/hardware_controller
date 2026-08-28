import Testing

@testable import HardwareControllerCore

struct VoiceFormattingDraftNormalizerTest {
  @Test
  func groceryCueBecomesAHeadingAndUnorderedItems() {
    let normalized = VoiceFormattingDraftNormalizer().normalize(
      .paragraph("Grocery list: apples, bananas, and coffee."),
      transcript: "grocery list: apples, bananas, and coffee",
      intent: .unordered
    )

    #expect(
      normalized
        == VoiceFormattingDraft(
          blocks: [
            VoiceFormattingDraftBlock(
              kind: .paragraph,
              items: ["grocery list:"]
            ),
            VoiceFormattingDraftBlock(
              kind: .unorderedList,
              items: ["apples", "bananas", "coffee"]
            ),
          ]
        )
    )
  }

  @Test
  func spokenOrdinalsBecomeAnOrderedList() {
    let transcript =
      "there are three steps first stop the service second copy the backup third restart the service"

    let normalized = VoiceFormattingDraftNormalizer().normalize(
      .paragraph(transcript),
      transcript: transcript,
      intent: .ordered
    )

    #expect(normalized.blocks.map(\.kind) == [.paragraph, .orderedList])
    #expect(normalized.blocks[0].items == ["there are three steps:"])
    #expect(
      normalized.blocks[1].items
        == [
          "stop the service",
          "copy the backup",
          "restart the service",
        ]
    )
  }

  @Test
  func explicitSpokenBulletMarkersBecomeUnorderedItems() {
    let transcript = "groceries\n- apples\n- bananas\n- coffee"

    let normalized = VoiceFormattingDraftNormalizer().normalize(
      .paragraph(transcript),
      transcript: transcript,
      intent: .unordered
    )

    #expect(normalized.blocks.map(\.kind) == [.paragraph, .unorderedList])
    #expect(normalized.blocks[0].items == ["groceries:"])
    #expect(normalized.blocks[1].items == ["apples", "bananas", "coffee"])
  }

  @Test
  func mixedExplicitListPreservesCanonicalProviderBlocks() {
    let providerOutput = VoiceFormattingDraft(
      blocks: [
        VoiceFormattingDraftBlock(
          kind: .paragraph,
          items: ["Intro"]
        ),
        VoiceFormattingDraftBlock(
          kind: .orderedList,
          items: ["First item", "Second item"]
        ),
        VoiceFormattingDraftBlock(
          kind: .paragraph,
          items: ["Outro"]
        ),
      ]
    )

    let normalized = VoiceFormattingDraftNormalizer().normalize(
      providerOutput,
      transcript: "Intro\n\n1. First item\n2. Second item\n\nOutro",
      intent: .ordered
    )

    #expect(normalized == providerOutput)
  }
}
