import CryptoKit
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerApp
@testable import HardwareControllerMac

@MainActor
struct SpeechEngineModelTest {
  private struct Fetcher: ASRModelFileFetching {
    let contents: [String: Data]

    func fetch(
      _ url: URL,
      to destination: URL,
      progress: @escaping @Sendable (Int64) -> Void
    ) async throws(ASRModelDownloadError) {
      guard let data = contents[url.lastPathComponent] else {
        throw .transferFailed("offline")
      }
      do {
        try data.write(to: destination)
      } catch {
        throw .transferFailed("fixture")
      }
      progress(Int64(data.count))
    }
  }

  private final class Applied {
    var configurations: [SpeechEngineConfiguration] = []
    var persisted: [SpeechEngine] = []
  }

  private static let files: [String: Data] = [
    "model.gguf": Data(repeating: 1, count: 2_048),
    "vad.gguf": Data(repeating: 2, count: 256),
  ]

  private static func catalog() throws -> ASRModelCatalogEntry {
    let base = try #require(URL(string: "https://example.invalid/resolve/abc"))
    let file = { (name: String, role: String) in
      ASRModelCatalogFile(
        name: name,
        url: base.appending(path: name),
        sha256: SHA256.hash(data: files[name] ?? Data()).map { String(format: "%02x", $0) }
          .joined(),
        bytes: Int64(files[name]?.count ?? 0),
        role: role
      )
    }
    return ASRModelCatalogEntry(
      packageID: "com.longdevity.asr.fixture",
      version: "1",
      displayName: "Fixture Model",
      languages: ["en"],
      spdxExpression: "CC-BY-4.0",
      sourceURL: base,
      minimumMemoryBytes: 1,
      recommendedMemoryBytes: 1,
      files: [file("model.gguf", "model"), file("vad.gguf", "speech_detection")]
    )
  }

  private static func model(
    selection: SpeechEngine = .transcribeCpp,
    files: [String: Data] = files,
    applied: Applied
  ) throws -> (SpeechEngineModel, ASRModelPackageStore) {
    let store = ASRModelPackageStore(
      root: FileManager.default.temporaryDirectory.appending(
        path: "speech_model_\(UUID().uuidString)")
    )
    let model = SpeechEngineModel(
      selection: selection,
      store: store,
      catalog: try catalog(),
      fetcher: Fetcher(contents: files),
      persist: {
        applied.persisted.append($0)
        return true
      }
    )
    model.connect { applied.configurations.append($0) }
    return (model, store)
  }

  /// The default engine blocks Dictation until its package is installed.
  @Test
  func defaultEngineRequiresSetupUntilDownloaded() async throws {
    let applied = Applied()
    let (model, store) = try Self.model(applied: applied)
    defer { try? store.removeAll() }
    #expect(model.requiresSetup)

    model.startDownload()
    #expect(model.isDownloading)
    try await settle { !model.isDownloading }

    #expect(!model.requiresSetup)
    #expect(model.installedPackage?.displayName == "Fixture Model")
    #expect(applied.configurations.last?.package == model.installedPackage)
    #expect(store.installed() == model.installedPackage)
  }

  /// A failed download says why and leaves Dictation blocked, never on Apple.
  @Test
  func failedDownloadKeepsSetupRequired() async throws {
    let applied = Applied()
    let (model, store) = try Self.model(files: [:], applied: applied)
    defer { try? store.removeAll() }
    model.startDownload()
    try await settle { !model.isDownloading }
    #expect(model.downloadState == .failed("The download failed: offline"))
    #expect(model.requiresSetup)
    #expect(applied.configurations.isEmpty)
  }

  /// Choosing Apple is persisted and applied; it no longer requires setup.
  @Test
  func selectingApplePersistsAndApplies() throws {
    let applied = Applied()
    let (model, store) = try Self.model(applied: applied)
    defer { try? store.removeAll() }
    model.select(.apple)
    #expect(applied.persisted == [.apple])
    #expect(applied.configurations == [SpeechEngineConfiguration(selection: .apple, package: nil)])
    #expect(!model.requiresSetup)
    model.select(.apple)
    #expect(applied.persisted == [.apple])
  }

  @Test
  func removingTheModelRequiresSetupAgain() async throws {
    let applied = Applied()
    let (model, store) = try Self.model(applied: applied)
    defer { try? store.removeAll() }
    model.startDownload()
    try await settle { !model.isDownloading }
    model.removeModel()
    #expect(model.installedPackage == nil)
    #expect(model.requiresSetup)
  }
}

/// Polls a main-actor condition for up to ten seconds.
@MainActor
private func settle(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(10)
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("Timed out waiting for the condition.")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}
