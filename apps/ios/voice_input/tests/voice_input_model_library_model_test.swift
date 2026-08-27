import Foundation
import XCTest

@testable import VoiceInput

final class VoiceInputModelLibraryModelTest: XCTestCase {
  @MainActor
  func testRefreshLoadsInstalledPackages() async throws {
    let temporary = temporaryDirectory()
    let source = temporary.appendingPathComponent("source")
    try copyVoiceInputModelFixture(to: source)
    let installer = VoiceInputModelPackageInstaller(
      rootURL: temporary.appendingPathComponent("models")
    )
    _ = try await installer.install(from: source, expectedManifestSHA256: nil)
    let model = VoiceInputModelLibraryModel(installer: installer)

    await model.refresh()

    XCTAssertEqual(model.packages.count, 1)
    XCTAssertEqual(model.packages.first?.package.languages, ["en-US"])
    XCTAssertNil(model.errorMessage)
  }

  @MainActor
  func testImportCopiesAndReloadsAPackage() async throws {
    let temporary = temporaryDirectory()
    let source = temporary.appendingPathComponent("source")
    try copyVoiceInputModelFixture(to: source)
    let model = VoiceInputModelLibraryModel(
      installer: VoiceInputModelPackageInstaller(
        rootURL: temporary.appendingPathComponent("models")
      )
    )

    await model.importPackage(from: source)

    XCTAssertEqual(model.packages.count, 1)
    XCTAssertFalse(model.isImporting)
    XCTAssertNil(model.errorMessage)
  }

  @MainActor
  func testImportSurfacesTypedFailureAndKeepsExistingState() async {
    let temporary = temporaryDirectory()
    let model = VoiceInputModelLibraryModel(
      installer: VoiceInputModelPackageInstaller(
        rootURL: temporary.appendingPathComponent("models")
      )
    )

    await model.importPackage(from: temporary.appendingPathComponent("missing"))

    XCTAssertEqual(model.packages, [])
    XCTAssertFalse(model.isImporting)
    XCTAssertEqual(
      model.errorMessage,
      VoiceInputModelPackageInstallError.invalidSource.localizedDescription
    )
  }

  @MainActor
  func testRemoveReloadsTheLibrary() async throws {
    let temporary = temporaryDirectory()
    let source = temporary.appendingPathComponent("source")
    try copyVoiceInputModelFixture(to: source)
    let model = VoiceInputModelLibraryModel(
      installer: VoiceInputModelPackageInstaller(
        rootURL: temporary.appendingPathComponent("models")
      )
    )
    await model.importPackage(from: source)
    let installed = try XCTUnwrap(model.packages.first)

    await model.removePackage(installed)

    XCTAssertEqual(model.packages, [])
    XCTAssertNil(model.errorMessage)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
