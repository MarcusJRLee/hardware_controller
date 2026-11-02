import CryptoKit
import Foundation
import Testing

@testable import HardwareControllerMac

struct ASRModelDownloaderTest {
  /// Serves fixture bytes by file name, optionally corrupting one.
  private struct Fetcher: ASRModelFileFetching {
    let contents: [String: Data]
    var corrupt: String?

    func fetch(
      _ url: URL,
      to destination: URL,
      progress: @escaping @Sendable (Int64) -> Void
    ) async throws(ASRModelDownloadError) {
      var data = contents[url.lastPathComponent] ?? Data()
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

  private static let contents: [String: Data] = [
    "model.gguf": Data(repeating: 1, count: 4_096),
    "vad.gguf": Data(repeating: 2, count: 512),
    "LICENSE": Data("Attribution 4.0 International".utf8),
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
      languages: ["en"],
      spdxExpression: "CC-BY-4.0",
      sourceURL: base,
      minimumMemoryBytes: 1,
      recommendedMemoryBytes: 1,
      files: [
        file("model.gguf", "model"), file("vad.gguf", "speech_detection"), file("LICENSE", nil),
      ]
    )
  }

  private static func store() -> ASRModelPackageStore {
    ASRModelPackageStore(
      root: FileManager.default.temporaryDirectory.appending(path: "asr_store_\(UUID().uuidString)")
    )
  }

  /// A verified download assembles a package the Rust validator accepts.
  @Test
  func downloadsVerifiesAndInstalls() async throws {
    let store = Self.store()
    defer { try? store.removeAll() }
    let entry = try Self.entry()
    let progress = ProgressLog()
    let installed = try await ASRModelDownloader(
      entry: entry,
      store: store,
      fetcher: Fetcher(contents: Self.contents)
    ).download(progress: progress.record)
    #expect(installed.packageID == "com.longdevity.asr.fixture")
    #expect(installed.manifestSHA256.count == 32)
    #expect(store.installed() == installed)
    #expect(progress.last == entry.downloadBytes)
    let notice = try String(
      contentsOf: installed.rootURL.appending(path: "NOTICE.txt"), encoding: .utf8)
    #expect(notice.contains("Attribution 4.0 International"))
    // Staging is gone; only the package and its record remain.
    let names = try FileManager.default.contentsOfDirectory(atPath: store.root.path).sorted()
    #expect(names == [installed.rootURL.lastPathComponent, "installed.json"].sorted())
  }

  /// A corrupted file installs nothing and leaves the previous state intact.
  @Test
  func integrityMismatchInstallsNothing() async throws {
    let store = Self.store()
    defer { try? store.removeAll() }
    await #expect(throws: ASRModelDownloadError.integrityMismatch("model.gguf")) {
      _ = try await ASRModelDownloader(
        entry: try Self.entry(),
        store: store,
        fetcher: Fetcher(contents: Self.contents, corrupt: "model.gguf")
      ).download { _ in }
    }
    #expect(store.installed() == nil)
  }

  @Test
  func pinnedCatalogIsComplete() throws {
    let entry = try #require(ASRModelCatalog.parakeetV3)
    #expect(
      entry.files.allSatisfy { $0.url.scheme == "https" && $0.sha256.count == 64 && $0.bytes > 0 })
    #expect(entry.files.compactMap(\.role).sorted() == ["model", "speech_detection"])
    #expect(entry.downloadBytes > 700_000_000)
  }
}

private final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var received: Int64 = 0
  var last: Int64 { lock.withLock { received } }
  func record(_ progress: ASRModelDownloadProgress) {
    lock.withLock { received = progress.receivedBytes }
  }
}
