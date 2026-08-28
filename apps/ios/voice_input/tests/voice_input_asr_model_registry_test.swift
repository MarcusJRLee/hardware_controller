import Foundation
import XCTest

@testable import VoiceInput

final class VoiceInputASRModelRegistryTest: XCTestCase {
  func testCompatiblePackagePersistsAcrossRegistryInstances() async throws {
    let fixture = try whisperFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let installed = try await fixture.installer.install(
      from: fixture.source,
      expectedManifestSHA256: nil
    )
    let registry = VoiceInputASRModelRegistry(
      installer: fixture.installer,
      selectionURL: fixture.selectionURL
    )

    try await registry.selectASRModel(installed)
    let reloaded = VoiceInputASRModelRegistry(
      installer: fixture.installer,
      selectionURL: fixture.selectionURL
    )

    let selected = try await reloaded.selectedASRModel()
    XCTAssertEqual(selected, installed)
  }

  func testWrongRuntimeCannotBecomeActive() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let installed = try await fixture.installer.install(
      from: fixture.source,
      expectedManifestSHA256: nil
    )
    let registry = VoiceInputASRModelRegistry(
      installer: fixture.installer,
      selectionURL: fixture.selectionURL
    )

    do {
      try await registry.selectASRModel(installed)
      XCTFail("A sherpa-onnx package must not select the whisper.cpp adapter.")
    } catch {
      XCTAssertEqual(error as? VoiceInputASRModelRegistryError, .incompatiblePackage)
    }
  }

  func testRemovingActivePackageClearsSelection() async throws {
    let fixture = try whisperFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let installed = try await fixture.installer.install(
      from: fixture.source,
      expectedManifestSHA256: nil
    )
    let registry = VoiceInputASRModelRegistry(
      installer: fixture.installer,
      selectionURL: fixture.selectionURL
    )
    try await registry.selectASRModel(installed)

    try await registry.remove(installed)

    do {
      _ = try await registry.selectedASRModel()
      XCTFail("Removing the active package must clear its selection.")
    } catch {
      XCTAssertEqual(error as? VoiceInputASRModelRegistryError, .noSelection)
    }
  }

  func testCorruptedSelectionFailsExplicitly() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      at: fixture.selectionURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("not json".utf8).write(to: fixture.selectionURL)
    let registry = VoiceInputASRModelRegistry(
      installer: fixture.installer,
      selectionURL: fixture.selectionURL
    )

    do {
      _ = try await registry.selectedASRModel()
      XCTFail("Corrupted selection must not silently fall back.")
    } catch {
      XCTAssertEqual(error as? VoiceInputASRModelRegistryError, .invalidSelection)
    }
  }

  private func whisperFixture() throws -> Fixture {
    let fixture = try fixture()
    let manifestURL = fixture.source.appendingPathComponent("manifest.json")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    try manifest.replacingOccurrences(
      of: "\"runtime\": \"sherpa_onnx\"",
      with: "\"runtime\": \"whisper_cpp\""
    ).write(to: manifestURL, atomically: true, encoding: .utf8)
    return fixture
  }

  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    let source = root.appendingPathComponent("source", isDirectory: true)
    try copyVoiceInputModelFixture(to: source)
    let installer = VoiceInputModelPackageInstaller(
      rootURL: root.appendingPathComponent("models", isDirectory: true)
    )
    return Fixture(
      root: root,
      source: source,
      selectionURL: root.appendingPathComponent("active_asr.json"),
      installer: installer
    )
  }

  private struct Fixture {
    let root: URL
    let source: URL
    let selectionURL: URL
    let installer: VoiceInputModelPackageInstaller
  }
}
