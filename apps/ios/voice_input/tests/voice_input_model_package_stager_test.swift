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

  /// A device lists its container through /private/var while the app spells
  /// it /var; the simulator's /tmp → /private/tmp link behaves the same way.
  func testCopyFromASymlinkSpelledSourceKeepsTheLayout() throws {
    let temporary = try symlinkSpelledDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("source")
    let destination = temporary.appendingPathComponent("destination")
    try copyVoiceInputModelFixture(to: source)

    try VoiceInputModelPackageStager(limits: .standardModelPackage)
      .copy(from: source, to: destination)

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(),
      try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
    )
  }

  private func symlinkSpelledDirectory() throws -> URL {
    #if targetEnvironment(simulator)
      let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
    #else
      let base = try XCTUnwrap(
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      )
    #endif
    return base.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
