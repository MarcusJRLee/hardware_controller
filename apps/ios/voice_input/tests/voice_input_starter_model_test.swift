import CryptoKit
import Foundation
import XCTest

@testable import VoiceInput

final class VoiceInputStarterModelTest: XCTestCase {
  func testBundledManifestMatchesThePinnedDigest() throws {
    let starter = try XCTUnwrap(VoiceInputStarterModel())
    let manifest = try Data(
      contentsOf: starter.packageURL.appendingPathComponent("manifest.json")
    )
    XCTAssertEqual(Data(SHA256.hash(data: manifest)), VoiceInputStarterModel.manifestSHA256)
  }

  func testEmptyLibraryInstallsAndSelectsTheVerifiedStarter() async throws {
    let registry = makeRegistry()

    let outcome = try await XCTUnwrap(VoiceInputStarterModel())
      .provisionIfNeeded(manager: registry)

    XCTAssertEqual(outcome, .installed)
    let selected = try await registry.selectedASRModel()
    XCTAssertEqual(selected.package.packageID, "com.longdevity.asr.whisper_tiny_en")
    XCTAssertTrue(selected.publisherVerified)
  }

  func testActiveSelectionIsLeftAlone() async throws {
    let registry = makeRegistry()
    let starter = try XCTUnwrap(VoiceInputStarterModel())
    _ = try await starter.provisionIfNeeded(manager: registry)

    let outcome = try await starter.provisionIfNeeded(manager: registry)

    XCTAssertEqual(outcome, .unchanged)
  }

  func testAnUnselectedCompatibleModelKeepsTheUsersChoice() async throws {
    let root = temporaryDirectory()
    let registry = makeRegistry(root: root)
    let starter = try XCTUnwrap(VoiceInputStarterModel())
    let source = root.appendingPathComponent("user_model")
    try copyVoiceInputModelFixture(to: source)
    let manifestURL = source.appendingPathComponent("manifest.json")
    try String(contentsOf: manifestURL, encoding: .utf8)
      .replacingOccurrences(of: "\"sherpa_onnx\"", with: "\"transcribe_cpp\"")
      .write(to: manifestURL, atomically: true, encoding: .utf8)
    _ = try await registry.install(from: source, expectedManifestSHA256: nil)

    let outcome = try await starter.provisionIfNeeded(manager: registry)

    XCTAssertEqual(outcome, .unchanged)
    do {
      _ = try await registry.selectedASRModel()
      XCTFail("Provisioning must not select a model the user installed.")
    } catch VoiceInputASRModelRegistryError.noSelection {}
  }

  func testAnUnselectedStarterFromAnEarlierLaunchIsSelected() async throws {
    let registry = makeRegistry()
    let starter = try XCTUnwrap(VoiceInputStarterModel())
    _ = try await registry.install(
      from: starter.packageURL,
      expectedManifestSHA256: VoiceInputStarterModel.manifestSHA256
    )

    let outcome = try await starter.provisionIfNeeded(manager: registry)

    XCTAssertEqual(outcome, .installed)
    let selected = try await registry.selectedASRModel()
    XCTAssertTrue(selected.publisherVerified)
  }

  func testTamperedBundleFailsAdmission() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("starter")
    try FileManager.default.copyItem(
      at: try XCTUnwrap(VoiceInputStarterModel()).packageURL,
      to: source
    )
    try Data("tampered".utf8).write(to: source.appendingPathComponent("NOTICE.txt"))
    let registry = makeRegistry()

    do {
      _ = try await VoiceInputStarterModel(packageURL: source)
        .provisionIfNeeded(manager: registry)
      XCTFail("A drifted starter must not install.")
    } catch {
      let installed = try await registry.installedPackages()
      XCTAssertEqual(installed, [])
    }
  }

  private func makeRegistry(root: URL? = nil) -> VoiceInputASRModelRegistry {
    let root = root ?? temporaryDirectory()
    return VoiceInputASRModelRegistry(
      installer: VoiceInputModelPackageInstaller(
        rootURL: root.appendingPathComponent("models")
      ),
      selectionURL: root.appendingPathComponent("active_asr.json")
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
