import Foundation
import HardwareControllerVoiceFFI
import XCTest

final class VoiceInputModelPackageValidatorTest: XCTestCase {
  func testSharedFixtureCrossesTheLinkedIOSRustBoundary() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "valid", withExtension: nil)
    )

    let package = try RustPortableVoiceValidator().validateModelPackage(
      at: fixture,
      limits: .standardModelPackage,
      expectedManifestSHA256: nil
    )

    XCTAssertEqual(package.packageID, "com.longdevity.fixture.streaming_asr")
    XCTAssertEqual(package.stage, .asr)
    XCTAssertEqual(package.languages, ["en-US"])
    XCTAssertEqual(package.fileCount, 2)
  }
}
