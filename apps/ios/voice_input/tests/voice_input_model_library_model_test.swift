import CryptoKit
import Foundation
import HardwareControllerModelDownload
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
      with: "\"runtime\": \"transcribe_cpp\""
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

  @MainActor
  func testRefreshProvisionsTheStarterOncePerLaunch() async throws {
    let temporary = temporaryDirectory()
    let registry = manager(
      installer: VoiceInputModelPackageInstaller(
        rootURL: temporary.appendingPathComponent("models")),
      root: temporary
    )
    let model = VoiceInputModelLibraryModel(manager: registry, starter: VoiceInputStarterModel())

    await model.refresh()
    let starter = try XCTUnwrap(model.activeASRModel)
    XCTAssertFalse(model.isPreparingStarter)
    await model.removePackage(starter)
    await model.refresh()

    XCTAssertEqual(model.packages, [])
    XCTAssertNil(model.activeASRModel)
  }

  @MainActor
  func testDownloadInstallsVerifiesAndActivatesTheModel() async throws {
    let library = try await ModelLibraryFixture()
    let entry = try FixtureCatalog.entry()
    let model = VoiceInputModelLibraryModel(
      manager: library.registry,
      downloader: VoiceInputModelDownloader(
        stagingRoot: library.root.appendingPathComponent("downloads"),
        manager: library.registry,
        fetcher: FixtureCatalog.Fetcher()
      ),
      catalog: [entry]
    )

    model.download(entry)
    XCTAssertEqual(model.downloads[entry.packageID], 0)
    try await waitUntil("the download to settle") {
      model.downloads.isEmpty && model.activeASRModel != nil
    }

    XCTAssertEqual(model.activeASRModel?.package.packageID, entry.packageID)
    XCTAssertEqual(model.activeASRModel?.publisherVerified, true)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.choices.first?.state, .active)
  }

  @MainActor
  func testCorruptedDownloadInstallsNothingAndExplains() async throws {
    let library = try await ModelLibraryFixture()
    let entry = try FixtureCatalog.entry()
    let model = VoiceInputModelLibraryModel(
      manager: library.registry,
      downloader: VoiceInputModelDownloader(
        stagingRoot: library.root.appendingPathComponent("downloads"),
        manager: library.registry,
        fetcher: FixtureCatalog.Fetcher(corrupt: true)
      ),
      catalog: [entry]
    )

    model.download(entry)
    try await waitUntil("the download to settle") { model.downloads.isEmpty }

    XCTAssertEqual(
      model.errorMessage,
      "model.gguf did not match its pinned checksum, so nothing was installed."
    )
    let installed = try await library.registry.installedPackages()
    XCTAssertEqual(installed, [])
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

/// A one-package catalog served from memory with pinned digests.
private enum FixtureCatalog {
  static let contents: [String: Data] = [
    "model.gguf": Data(repeating: 7, count: 2_048),
    "vad.gguf": Data(repeating: 3, count: 256),
    "LICENSE": Data("Apache License 2.0".utf8),
  ]

  struct Fetcher: ASRModelFileFetching {
    var corrupt = false

    func fetch(
      _ url: URL,
      to destination: URL,
      progress: @escaping @Sendable (Int64) -> Void
    ) async throws(ASRModelDownloadError) {
      var data = FixtureCatalog.contents[url.lastPathComponent] ?? Data()
      if corrupt, url.lastPathComponent == "model.gguf" {
        data[0] ^= 0xff
      }
      do {
        try data.write(to: destination)
      } catch {
        throw .transferFailed("fixture")
      }
      progress(Int64(data.count))
    }
  }

  static func entry() throws -> ASRModelCatalogEntry {
    let base = try XCTUnwrap(URL(string: "https://example.invalid/resolve/abc"))
    func file(_ name: String, _ role: String?) -> ASRModelCatalogFile {
      let data = contents[name] ?? Data()
      return ASRModelCatalogFile(
        name: name == "LICENSE" ? "model-LICENSE.txt" : name,
        url: base.appending(path: name),
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        bytes: Int64(data.count),
        role: role
      )
    }
    return ASRModelCatalogEntry(
      packageID: "com.longdevity.asr.fixture_download",
      version: "1",
      displayName: "Fixture Download",
      languages: ["en-US"],
      spdxExpression: "Apache-2.0",
      sourceURL: base,
      minimumMemoryBytes: 1,
      recommendedMemoryBytes: 1,
      files: [
        file("model.gguf", "model"), file("vad.gguf", "speech_detection"), file("LICENSE", nil),
      ]
    )
  }
}
