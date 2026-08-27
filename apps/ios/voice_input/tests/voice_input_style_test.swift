import XCTest

@testable import VoiceInputShared

final class VoiceInputStyleTest: XCTestCase {
  func testFiveStylesHaveStableCanonicalIdentifiersAndLabels() {
    XCTAssertEqual(
      VoiceInputStyleKind.allCases.map(\.rawValue),
      ["natural", "casualMessage", "formal", "technical", "verbatim"]
    )
    XCTAssertEqual(
      VoiceInputStyleKind.allCases.map(\.displayName),
      ["Natural", "Casual", "Formal", "Technical", "Verbatim"]
    )
  }
}
