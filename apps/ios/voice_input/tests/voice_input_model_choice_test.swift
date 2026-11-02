import Foundation
import HardwareControllerModelDownload
import XCTest

@testable import VoiceInput

final class VoiceInputModelChoiceTest: XCTestCase {
  func testBuiltInLeadsThenCatalogThenImports() async throws {
    let library = try await ModelLibraryFixture()
    let builtIn = try await library.installStarter()
    let imported = try await library.installFixture()
    let catalog = [ASRModelCatalog.whisperBaseEnglish, ASRModelCatalog.parakeetV3]
      .compactMap { $0 }
    XCTAssertEqual(catalog.count, 2)

    let choices = VoiceInputModelChoice.choices(
      installed: [imported, builtIn],
      active: builtIn,
      catalog: catalog,
      downloads: ["com.longdevity.asr.parakeet_tdt_v3": 0.25]
    )

    XCTAssertEqual(
      choices.map(\.id),
      [
        VoiceInputModelChoice.builtInPackageID, "com.longdevity.asr.whisper_base_en",
        "com.longdevity.asr.parakeet_tdt_v3", imported.package.packageID,
      ])
    XCTAssertEqual(choices[0].state, .active)
    XCTAssertEqual(choices[1].state, .available(catalog[0]))
    XCTAssertEqual(choices[2].state, .downloading(catalog[1], fraction: 0.25))
    XCTAssertEqual(choices[3].state, .installed(imported))
    XCTAssertEqual(choices[3].summary, "Imported from Files")
    XCTAssertNil(choices[1].installed)
  }

  func testAnInstalledCatalogPackageReplacesItsDownloadRow() async throws {
    let library = try await ModelLibraryFixture()
    let builtIn = try await library.installStarter()
    let catalog = [try XCTUnwrap(ASRModelCatalog.whisperBaseEnglish)]

    let choices = VoiceInputModelChoice.choices(
      installed: [builtIn],
      active: nil,
      catalog: catalog,
      downloads: [:]
    )

    XCTAssertEqual(choices.first?.state, .installed(builtIn))
    XCTAssertEqual(choices.count, 2)
  }
}

/// A private library holding the bundled starter and the shared fixture.
struct ModelLibraryFixture {
  let root: URL
  let registry: VoiceInputASRModelRegistry

  init() async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    registry = VoiceInputASRModelRegistry(
      installer: VoiceInputModelPackageInstaller(
        rootURL: root.appendingPathComponent("models", isDirectory: true)
      ),
      selectionURL: root.appendingPathComponent("active_asr.json")
    )
  }

  func installStarter() async throws -> VoiceInputInstalledModelPackage {
    try await registry.install(
      from: try XCTUnwrap(VoiceInputStarterModel()).packageURL,
      expectedManifestSHA256: VoiceInputStarterModel.manifestSHA256
    )
  }

  /// The shared fixture, rewritten as a compatible transcribe.cpp package.
  func installFixture() async throws -> VoiceInputInstalledModelPackage {
    let source = root.appendingPathComponent("fixture", isDirectory: true)
    try copyVoiceInputModelFixture(to: source)
    let manifestURL = source.appendingPathComponent("manifest.json")
    try String(contentsOf: manifestURL, encoding: .utf8)
      .replacingOccurrences(of: "\"sherpa_onnx\"", with: "\"transcribe_cpp\"")
      .write(to: manifestURL, atomically: true, encoding: .utf8)
    return try await registry.install(from: source, expectedManifestSHA256: nil)
  }
}
