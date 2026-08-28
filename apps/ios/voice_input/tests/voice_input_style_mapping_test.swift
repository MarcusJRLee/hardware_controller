import HardwareControllerVoiceCore
import VoiceInputShared
import XCTest

@testable import VoiceInput

final class VoiceInputStyleMappingTest: XCTestCase {
  func testEveryHandoffStyleMapsExactlyToTheCanonicalDomainStyle() {
    XCTAssertEqual(
      VoiceInputStyleKind.allCases.map(\.domainStyle),
      [
        VoiceStyle.natural,
        .casualMessage,
        .formal,
        .technical,
        .verbatim,
      ]
    )
  }
}
