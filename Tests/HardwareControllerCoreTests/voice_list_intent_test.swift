import Testing

@testable import HardwareControllerCore

struct VoiceListIntentDetectorTest {
  @Test
  func groceryListWithDelimitedItemsIsUnordered() {
    let intent = VoiceListIntentDetector().detect(
      in: "grocery list: apples, bananas, and coffee"
    )

    #expect(intent == .unordered)
  }
}
