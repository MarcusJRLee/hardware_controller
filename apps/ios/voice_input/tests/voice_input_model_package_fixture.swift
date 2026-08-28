import Foundation
import XCTest

func copyVoiceInputModelFixture(to destination: URL) throws {
  let source = try XCTUnwrap(
    Bundle(for: VoiceInputModelPackageValidatorTest.self)
      .url(forResource: "valid", withExtension: nil)
  )
  try FileManager.default.createDirectory(
    at: destination.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try FileManager.default.copyItem(at: source, to: destination)
}
