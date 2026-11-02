import CryptoKit
import Foundation

/// Bytes received so far out of the package total.
public struct ASRModelDownloadProgress: Equatable, Sendable {
  public let receivedBytes: Int64
  public let totalBytes: Int64

  public init(receivedBytes: Int64, totalBytes: Int64) {
    self.receivedBytes = receivedBytes
    self.totalBytes = totalBytes
  }

  public var fraction: Double {
    totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
  }
}

/// Downloads, verifies, and assembles one catalog package in a staging
/// directory the caller owns; each app then installs it through its own
/// Rust-validated store.
public struct ASRModelPackageAssembler: Sendable {
  private let entry: ASRModelCatalogEntry
  private let fetcher: any ASRModelFileFetching

  public init(
    entry: ASRModelCatalogEntry,
    fetcher: any ASRModelFileFetching = URLSessionModelFileFetcher()
  ) {
    self.entry = entry
    self.fetcher = fetcher
  }

  /// Fills `staging`, an existing empty directory, with a complete package and
  /// returns its manifest's SHA-256. Every file matched its pinned size and
  /// digest, so the generated manifest is pinned transitively.
  public func assemble(
    in staging: URL,
    progress: @escaping @Sendable (ASRModelDownloadProgress) -> Void
  ) async throws(ASRModelDownloadError) -> Data {
    let fileManager = FileManager.default
    let total = entry.downloadBytes
    var completed: Int64 = 0
    for file in entry.files {
      try Task.checkCancellation(or: .cancelled)
      let destination = staging.appending(path: file.name)
      let base = completed
      try await fetcher.fetch(file.url, to: destination) { received in
        progress(ASRModelDownloadProgress(receivedBytes: base + received, totalBytes: total))
      }
      guard
        let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
        (attributes[.size] as? NSNumber)?.int64Value == file.bytes,
        (try? Self.sha256(of: destination)) == file.sha256
      else {
        throw .integrityMismatch(file.name)
      }
      completed += file.bytes
    }
    try writeNotice(in: staging)
    try writeManifest(in: staging)
    do {
      return Data(SHA256.hash(data: try Data(contentsOf: staging.appending(path: "manifest.json"))))
    } catch {
      throw .installFailed(error.localizedDescription)
    }
  }

  /// Folds every license into one notice file, as the package schema requires.
  private func writeNotice(in staging: URL) throws(ASRModelDownloadError) {
    var notice = "\(entry.displayName) with Silero speech detection for local Voice.\n\n"
    notice += "Runtime source: https://github.com/handy-computer/transcribe.cpp\n"
    for file in entry.files where file.role == nil {
      guard let text = try? String(contentsOf: staging.appending(path: file.name), encoding: .utf8)
      else {
        throw .integrityMismatch(file.name)
      }
      notice += "\n== \(file.name) ==\n\(text)\n"
      try? FileManager.default.removeItem(at: staging.appending(path: file.name))
    }
    do {
      try Data(notice.utf8).write(to: staging.appending(path: "NOTICE.txt"), options: .atomic)
    } catch {
      throw .installFailed(error.localizedDescription)
    }
  }

  private func writeManifest(in staging: URL) throws(ASRModelDownloadError) {
    struct Manifest: Encodable {
      struct License: Encodable {
        let spdxExpression: String
        let noticeFile: String
        let sourceUrl: String
      }
      struct Resources: Encodable {
        let minimumMemoryBytes: Int64
        let recommendedMemoryBytes: Int64
      }
      struct File: Encodable {
        let path: String
        let role: String
        let bytes: Int64
        let sha256: String
      }
      let schemaVersion = 1
      let packageId: String
      let version: String
      let displayName: String
      let runtime = "transcribe_cpp"
      let stage = "asr"
      let capabilities = ["file_asr"]
      let languages: [String]
      let license: License
      let resources: Resources
      let files: [File]
    }
    let noticeURL = staging.appending(path: "NOTICE.txt")
    let noticeBytes: Int64
    let noticeDigest: String
    do {
      noticeBytes = Int64(try Data(contentsOf: noticeURL).count)
      noticeDigest = try Self.sha256(of: noticeURL)
    } catch {
      throw .installFailed(error.localizedDescription)
    }
    let manifest = Manifest(
      packageId: entry.packageID,
      version: entry.version,
      displayName: entry.displayName,
      languages: entry.languages,
      license: Manifest.License(
        spdxExpression: entry.spdxExpression,
        noticeFile: "NOTICE.txt",
        sourceUrl: entry.sourceURL.absoluteString
      ),
      resources: Manifest.Resources(
        minimumMemoryBytes: entry.minimumMemoryBytes,
        recommendedMemoryBytes: entry.recommendedMemoryBytes
      ),
      files: entry.files.compactMap { file in
        file.role.map {
          Manifest.File(path: file.name, role: $0, bytes: file.bytes, sha256: file.sha256)
        }
      } + [
        Manifest.File(path: "NOTICE.txt", role: "notice", bytes: noticeBytes, sha256: noticeDigest)
      ]
    )
    do {
      let encoder = JSONEncoder()
      // The schema's snake_case keys come from camelCase Swift properties.
      encoder.keyEncodingStrategy = .convertToSnakeCase
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(manifest).write(
        to: staging.appending(path: "manifest.json"), options: .atomic)
    } catch {
      throw .installFailed(error.localizedDescription)
    }
  }

  static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

extension Task where Success == Never, Failure == Never {
  fileprivate static func checkCancellation(
    or error: ASRModelDownloadError
  ) throws(ASRModelDownloadError) {
    if Task.isCancelled {
      throw error
    }
  }
}
