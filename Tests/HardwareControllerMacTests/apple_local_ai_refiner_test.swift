import Testing

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
}
