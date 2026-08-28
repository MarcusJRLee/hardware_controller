import Foundation
import HardwareControllerVoiceFFI
import XCTest

@testable import VoiceInput

final class VoiceInputModelPackageStagerTest: XCTestCase {
  func testCopyRejectsSourceBytesAboveTheConfiguredLimit() throws {
    let temporary = temporaryDirectory()
    let source = temporary.appendingPathComponent("source")
    let destination = temporary.appendingPathComponent("destination")
    try copyVoiceInputModelFixture(to: source)
    let stager = VoiceInputModelPackageStager(
      limits: PortableModelPackageLimits(
        maximumManifestBytes: 1,
        maximumInstalledBytes: 1,
        maximumFileCount: 2
      )
    )

    XCTAssertThrowsError(try stager.copy(from: source, to: destination)) { error in
      XCTAssertEqual(error as? VoiceInputModelPackageInstallError, .sourceLimitExceeded)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testCopyRejectsSymbolicLinks() throws {
    let temporary = temporaryDirectory()
    let source = temporary.appendingPathComponent("source")
    let destination = temporary.appendingPathComponent("destination")
    try copyVoiceInputModelFixture(to: source)
    try FileManager.default.createSymbolicLink(
      at: source.appendingPathComponent("linked.bin"),
      withDestinationURL: source.appendingPathComponent("model.bin")
    )

    XCTAssertThrowsError(
      try VoiceInputModelPackageStager(limits: .standardModelPackage)
        .copy(from: source, to: destination)
    ) { error in
      XCTAssertEqual(error as? VoiceInputModelPackageInstallError, .sourceInventoryInvalid)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
