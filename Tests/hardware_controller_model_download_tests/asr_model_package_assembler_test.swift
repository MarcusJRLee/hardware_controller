import CryptoKit
import Foundation
import Testing

@testable import HardwareControllerModelDownload

struct ASRModelPackageAssemblerTest {
  /// Serves fixture bytes by file name, optionally corrupting one.
  private struct Fetcher: ASRModelFileFetching {
    var corrupt: String?

    func fetch(
      _ url: URL,
      to destination: URL,
      progress: @escaping @Sendable (Int64) -> Void
    ) async throws(ASRModelDownloadError) {
      var data = ASRModelPackageAssemblerTest.contents[url.lastPathComponent] ?? Data()
      if url.lastPathComponent == corrupt {
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

  fileprivate static let contents: [String: Data] = [
    "model.gguf": Data(repeating: 1, count: 4_096),
    "vad.gguf": Data(repeating: 2, count: 512),
    "LICENSE": Data("Apache License 2.0".utf8),
  ]

  private static func entry() throws -> ASRModelCatalogEntry {
    let base = try #require(URL(string: "https://example.invalid/resolve/abc"))
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
      packageID: "com.longdevity.asr.fixture",
      version: "1",
      displayName: "Fixture",
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

  private static func staging() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "assembler_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test
  func assemblesAPinnedPackageAndReturnsItsManifestDigest() async throws {
    let staging = try Self.staging()
    defer { try? FileManager.default.removeItem(at: staging) }

    let digest = try await ASRModelPackageAssembler(entry: try Self.entry(), fetcher: Fetcher())
      .assemble(in: staging) { _ in }

    let manifest = try Data(contentsOf: staging.appending(path: "manifest.json"))
    #expect(digest == Data(SHA256.hash(data: manifest)))
    let names = try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()
    #expect(names == ["NOTICE.txt", "manifest.json", "model.gguf", "vad.gguf"])
    let notice = try String(contentsOf: staging.appending(path: "NOTICE.txt"), encoding: .utf8)
    #expect(notice.contains("Apache License 2.0"))
  }

  @Test
  func aCorruptedFileStopsAssembly() async throws {
    let staging = try Self.staging()
    defer { try? FileManager.default.removeItem(at: staging) }
    await #expect(throws: ASRModelDownloadError.integrityMismatch("vad.gguf")) {
      _ = try await ASRModelPackageAssembler(
        entry: try Self.entry(), fetcher: Fetcher(corrupt: "vad.gguf")
      ).assemble(in: staging) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: staging.appending(path: "manifest.json").path))
  }
}
