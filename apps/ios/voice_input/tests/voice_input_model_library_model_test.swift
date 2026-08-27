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
    let model = VoiceInputModelLibraryModel(
      manager: manager(installer: installer, root: temporary)
    )

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
    let installer = VoiceInputModelPackageInstaller(
      rootURL: temporary.appendingPathComponent("models")
    )
    let model = VoiceInputModelLibraryModel(
      manager: manager(installer: installer, root: temporary)
    )

    await model.importPackage(from: source)

    XCTAssertEqual(model.packages.count, 1)
    XCTAssertFalse(model.isImporting)
    XCTAssertNil(model.errorMessage)
  }

  @MainActor
  func testImportSurfacesTypedFailureAndKeepsExistingState() async {
    let temporary = temporaryDirectory()
    let installer = VoiceInputModelPackageInstaller(
      rootURL: temporary.appendingPathComponent("models")
    )
    let model = VoiceInputModelLibraryModel(
      manager: manager(installer: installer, root: temporary)
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
    let installer = VoiceInputModelPackageInstaller(
      rootURL: temporary.appendingPathComponent("models")
    )
    let model = VoiceInputModelLibraryModel(
      manager: manager(installer: installer, root: temporary)
    )
    await model.importPackage(from: source)
    let installed = try XCTUnwrap(model.packages.first)

    await model.removePackage(installed)

    XCTAssertEqual(model.packages, [])
    XCTAssertNil(model.errorMessage)
  }

  @MainActor
  func testRefreshKeepsTheActiveSelectionWhenPrewarmFails() async throws {
    let temporary = temporaryDirectory()
    let source = temporary.appendingPathComponent("source")
    try copyVoiceInputModelFixture(to: source)
    let manifestURL = source.appendingPathComponent("manifest.json")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    try manifest.replacingOccurrences(
      of: "\"runtime\": \"sherpa_onnx\"",
      with: "\"runtime\": \"whisper_cpp\""
    ).write(to: manifestURL, atomically: true, encoding: .utf8)
    let installer = VoiceInputModelPackageInstaller(
      rootURL: temporary.appendingPathComponent("models")
    )
    let registry = manager(installer: installer, root: temporary)
    let installed = try await registry.install(
      from: source,
      expectedManifestSHA256: nil
    )
    try await registry.selectASRModel(installed)
    let workflow = VoiceInputASRWorkflow(
      modelProvider: registry,
      transcriber: FailingPrewarmTranscriber()
    )
    let model = VoiceInputModelLibraryModel(
      manager: registry,
      asrWorkflow: workflow
    )

    await model.refresh()

    XCTAssertEqual(model.activeASRModel, installed)
    XCTAssertEqual(
      model.errorMessage,
      VoiceInputTranscriptionError.modelLoadFailed.localizedDescription
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func manager(
    installer: VoiceInputModelPackageInstaller,
    root: URL
  ) -> VoiceInputASRModelRegistry {
    VoiceInputASRModelRegistry(
      installer: installer,
      selectionURL: root.appendingPathComponent("active_asr.json")
    )
  }
}

private struct FailingPrewarmTranscriber: VoiceInputTranscribing {
  func prewarm(model _: VoiceInputInstalledModelPackage) async throws {
    throw VoiceInputTranscriptionError.modelLoadFailed
  }

  func transcribe(
    audioURL _: URL,
    model _: VoiceInputInstalledModelPackage
  ) async throws -> VoiceInputRawTranscript {
    throw VoiceInputTranscriptionError.modelLoadFailed
  }
}
