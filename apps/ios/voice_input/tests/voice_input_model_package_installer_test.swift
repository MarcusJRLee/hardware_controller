import Foundation
import HardwareControllerVoiceFFI
import XCTest

@testable import VoiceInput

final class VoiceInputModelPackageInstallerTest: XCTestCase {
  func testValidPackageInstallsIdempotentlyAndReloads() async throws {
    let temporary = temporaryDirectory()
    let source = temporary.appendingPathComponent("source")
    let modelRoot = temporary.appendingPathComponent("models")
    try copyVoiceInputModelFixture(to: source)
    let installer = VoiceInputModelPackageInstaller(rootURL: modelRoot)

    let first = try await installer.install(
      from: source,
      expectedManifestSHA256: nil
    )
    let second = try await installer.install(
      from: source,
      expectedManifestSHA256: nil
    )
    let reloaded = try await installer.installedPackages()

    XCTAssertEqual(first, second)
    XCTAssertEqual(reloaded, [first])
    XCTAssertEqual(first.package.languages, ["en-US"])
    XCTAssertFalse(first.publisherVerified)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: first.rootURL.appendingPathComponent("model.bin").path
      )
    )
    XCTAssertEqual(
      try modelRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup,
      true
    )
  }

  func testConflictingBytesForOneIdentityFailClosed() async throws {
    let temporary = temporaryDirectory()
    let firstSource = temporary.appendingPathComponent("first")
    let secondSource = temporary.appendingPathComponent("second")
    try copyVoiceInputModelFixture(to: firstSource)
    try copyVoiceInputModelFixture(to: secondSource)
    let manifestURL = secondSource.appendingPathComponent("manifest.json")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    try manifest.replacingOccurrences(
      of: "Fixture Streaming ASR",
      with: "Fixture Alternate ASR"
    ).write(to: manifestURL, atomically: true, encoding: .utf8)
    let installer = VoiceInputModelPackageInstaller(
      rootURL: temporary.appendingPathComponent("models")
    )
    _ = try await installer.install(
      from: firstSource,
      expectedManifestSHA256: nil
    )

    do {
      _ = try await installer.install(
        from: secondSource,
        expectedManifestSHA256: nil
      )
      XCTFail("A conflicting package identity must not replace installed bytes.")
    } catch {
      XCTAssertEqual(error as? VoiceInputModelPackageInstallError, .identityConflict)
    }
  }

  func testInvalidPackageLeavesNoStagingArtifact() async throws {
    let temporary = temporaryDirectory()
    let source = temporary.appendingPathComponent("source")
    let root = temporary.appendingPathComponent("models")
    try copyVoiceInputModelFixture(to: source)
    try Data("tampered".utf8).write(to: source.appendingPathComponent("model.bin"))
    let installer = VoiceInputModelPackageInstaller(rootURL: root)

    do {
      _ = try await installer.install(
        from: source,
        expectedManifestSHA256: nil
      )
      XCTFail("Tampered model bytes must not install.")
    } catch let error as VoiceInputModelPackageInstallError {
      guard case .validation = error else {
        return XCTFail("Expected a typed validation failure, got \(error).")
      }
    }

    let staging = root.appendingPathComponent("staging")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: staging.path),
      []
    )
  }

  func testCorruptInstallRecordFailsWithTypedStorageError() async throws {
    let temporary = temporaryDirectory()
    let source = temporary.appendingPathComponent("source")
    let root = temporary.appendingPathComponent("models")
    try copyVoiceInputModelFixture(to: source)
    let installer = VoiceInputModelPackageInstaller(rootURL: root)
    let package = try await installer.install(
      from: source,
      expectedManifestSHA256: nil
    )
    let record =
      root
      .appendingPathComponent("records")
      .appendingPathComponent(package.package.packageID)
      .appendingPathComponent("\(package.package.version).json")
    try Data("not-json".utf8).write(to: record)

    do {
      _ = try await installer.installedPackages()
      XCTFail("A corrupt provenance record must fail closed.")
    } catch {
      XCTAssertEqual(
        error as? VoiceInputModelPackageInstallError,
        .inputOutputFailure
      )
    }
  }

  func testTotalLibraryByteLimitRejectsAnotherPackage() async throws {
    let temporary = temporaryDirectory()
    let firstSource = temporary.appendingPathComponent("first")
    let secondSource = temporary.appendingPathComponent("second")
    try copyVoiceInputModelFixture(to: firstSource)
    try copyVoiceInputModelFixture(to: secondSource)
    let manifestURL = secondSource.appendingPathComponent("manifest.json")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    try manifest.replacingOccurrences(
      of: "com.longdevity.fixture.streaming_asr",
      with: "com.longdevity.fixture.streaming_bsr"
    ).write(to: manifestURL, atomically: true, encoding: .utf8)
    let package = try RustPortableVoiceValidator().validateModelPackage(
      at: firstSource,
      limits: .standardModelPackage,
      expectedManifestSHA256: nil
    )
    let installer = VoiceInputModelPackageInstaller(
      rootURL: temporary.appendingPathComponent("models"),
      libraryLimits: VoiceInputModelLibraryLimits(
        maximumStoredBytes: package.verifiedBytes,
        maximumPackageVersions: 2
      )
    )
    _ = try await installer.install(
      from: firstSource,
      expectedManifestSHA256: nil
    )

    do {
      _ = try await installer.install(
        from: secondSource,
        expectedManifestSHA256: nil
      )
      XCTFail("The configured total Model-library byte limit must fail closed.")
    } catch {
      XCTAssertEqual(
        error as? VoiceInputModelPackageInstallError,
        .libraryLimitExceeded
      )
    }
  }

  func testTotalLibraryPackageLimitRejectsAnotherVersion() async throws {
    let temporary = temporaryDirectory()
    let firstSource = temporary.appendingPathComponent("first")
    let secondSource = temporary.appendingPathComponent("second")
    try copyVoiceInputModelFixture(to: firstSource)
    try copyVoiceInputModelFixture(to: secondSource)
    let manifestURL = secondSource.appendingPathComponent("manifest.json")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    try manifest.replacingOccurrences(
      of: "\"version\": \"1.0.0\"",
      with: "\"version\": \"1.0.1\""
    ).write(to: manifestURL, atomically: true, encoding: .utf8)
    let installer = VoiceInputModelPackageInstaller(
      rootURL: temporary.appendingPathComponent("models"),
      libraryLimits: VoiceInputModelLibraryLimits(
        maximumStoredBytes: .max,
        maximumPackageVersions: 1
      )
    )
    _ = try await installer.install(
      from: firstSource,
      expectedManifestSHA256: nil
    )

    do {
      _ = try await installer.install(
        from: secondSource,
        expectedManifestSHA256: nil
      )
      XCTFail("The configured Model-library package limit must fail closed.")
    } catch {
      XCTAssertEqual(
        error as? VoiceInputModelPackageInstallError,
        .libraryLimitExceeded
      )
    }
  }

  func testExplicitRemovalDeletesOnlyTheInstalledCopy() async throws {
    let temporary = temporaryDirectory()
    let source = temporary.appendingPathComponent("source")
    try copyVoiceInputModelFixture(to: source)
    let installer = VoiceInputModelPackageInstaller(
      rootURL: temporary.appendingPathComponent("models")
    )
    let installed = try await installer.install(
      from: source,
      expectedManifestSHA256: nil
    )

    try await installer.remove(installed)
    let remaining = try await installer.installedPackages()

    XCTAssertEqual(remaining, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: installed.rootURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
