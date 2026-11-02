import CryptoKit
import Foundation

/// One pinned file the downloader fetches and verifies.
public struct ASRModelCatalogFile: Equatable, Sendable {
  public let name: String
  public let url: URL
  public let sha256: String
  public let bytes: Int64
  /// The manifest role, or nil for license text folded into the notice.
  public let role: String?
}

/// The pinned Model package the app offers to download (decision 0060).
public struct ASRModelCatalogEntry: Equatable, Sendable {
  public let packageID: String
  public let version: String
  public let displayName: String
  public let languages: [String]
  public let spdxExpression: String
  public let sourceURL: URL
  public let minimumMemoryBytes: Int64
  public let recommendedMemoryBytes: Int64
  public let files: [ASRModelCatalogFile]

  public var downloadBytes: Int64 {
    files.reduce(0) { $0 + $1.bytes }
  }
}

public enum ASRModelCatalog {
  // Revisions are immutable Hugging Face commits; digests are verified before
  // any file reaches the Rust validator. Updating a pin is a reviewed change.
  private static let parakeetRevision = URL(
    string:
      "https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf/resolve/d8d8c32cb2017c57e5307767343e97870f8a7f53"
  )
  private static let speechRevision = URL(
    string:
      "https://huggingface.co/handy-computer/silero-vad-v6.2-gguf/resolve/a9b2d61c20ae4ddf3644edb34969e8185a485448"
  )

  /// Parakeet TDT 0.6B v3 Q8_0 with Silero speech detection.
  public static let parakeetV3: ASRModelCatalogEntry? = {
    guard let parakeetRevision, let speechRevision else {
      return nil
    }
    return ASRModelCatalogEntry(
      packageID: "com.longdevity.asr.parakeet_tdt_v3",
      version: "d8d8c32-q8_0",
      displayName: "Parakeet TDT 0.6B v3",
      // The 25 European languages Parakeet v3 was trained on.
      languages: [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
      ],
      spdxExpression: "CC-BY-4.0 AND MIT",
      sourceURL: parakeetRevision.deletingLastPathComponent().deletingLastPathComponent(),
      minimumMemoryBytes: 1_073_741_824,
      recommendedMemoryBytes: 2_147_483_648,
      files: [
        ASRModelCatalogFile(
          name: "parakeet-tdt-0.6b-v3-Q8_0.gguf",
          url: parakeetRevision.appending(path: "parakeet-tdt-0.6b-v3-Q8_0.gguf"),
          sha256: "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7",
          bytes: 739_508_576,
          role: "model"
        ),
        ASRModelCatalogFile(
          name: "silero-vad-v6.2-F32.gguf",
          url: speechRevision.appending(path: "silero-vad-v6.2-F32.gguf"),
          sha256: "0d871a800c420fdd5d1b17a3aea4296d1c39608f0ff4a9295eb76457eb1c88e6",
          bytes: 1_241_056,
          role: "speech_detection"
        ),
        ASRModelCatalogFile(
          name: "parakeet-LICENSE.txt",
          url: parakeetRevision.appending(path: "LICENSE"),
          sha256: "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411",
          bytes: 18_657,
          role: nil
        ),
        ASRModelCatalogFile(
          name: "parakeet-NOTICE.txt",
          url: parakeetRevision.appending(path: "NOTICE"),
          sha256: "6f02c515f3deed71bb0e8909c8d8449faeb365ae507f67cd026c677b1bddcec8",
          bytes: 400,
          role: nil
        ),
        ASRModelCatalogFile(
          name: "silero-LICENSE.txt",
          url: speechRevision.appending(path: "LICENSE"),
          sha256: "2e63e9a38b6e8fc0c7bc37ce174caca1862870856c6daf5697cfb785e925520b",
          bytes: 1_075,
          role: nil
        ),
        ASRModelCatalogFile(
          name: "silero-NOTICE.txt",
          url: speechRevision.appending(path: "NOTICE"),
          sha256: "f1ea43096a23b40d4b14fcf131586710035444e69e35051c5d83c60725b50555",
          bytes: 293,
          role: nil
        ),
      ]
    )
  }()
}

public enum ASRModelDownloadError: Error, Equatable, Sendable {
  case catalogUnavailable
  case transferFailed(String)
  /// A file's size or digest differed from its pin; nothing was installed.
  case integrityMismatch(String)
  case installFailed(String)
  case cancelled
}

/// Fetches one URL to a local file; the only network code on macOS besides Ollama.
public protocol ASRModelFileFetching: Sendable {
  func fetch(
    _ url: URL,
    to destination: URL,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws(ASRModelDownloadError)
}

/// Downloads over HTTPS with no cookies, cache, or credentials.
public struct URLSessionModelFileFetcher: ASRModelFileFetching {
  public init() {}

  public func fetch(
    _ url: URL,
    to destination: URL,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws(ASRModelDownloadError) {
    guard url.scheme == "https" else {
      throw .transferFailed("Model downloads must use HTTPS.")
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    let session = URLSession(
      configuration: configuration, delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    do {
      let (bytes, response) = try await session.bytes(from: url)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw ASRModelDownloadError.transferFailed("The model server refused the download.")
      }
      FileManager.default.createFile(atPath: destination.path, contents: nil)
      let handle = try FileHandle(forWritingTo: destination)
      defer { try? handle.close() }
      var buffer = Data()
      buffer.reserveCapacity(1 << 20)
      var written: Int64 = 0
      for try await byte in bytes {
        buffer.append(byte)
        if buffer.count >= 1 << 20 {
          try handle.write(contentsOf: buffer)
          written += Int64(buffer.count)
          buffer.removeAll(keepingCapacity: true)
          progress(written)
        }
      }
      try handle.write(contentsOf: buffer)
      progress(written + Int64(buffer.count))
    } catch is CancellationError {
      throw .cancelled
    } catch let error as ASRModelDownloadError {
      throw error
    } catch {
      throw .transferFailed(error.localizedDescription)
    }
  }
}

/// Refuses any redirect that leaves HTTPS.
private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    request.url?.scheme == "https" ? request : nil
  }
}

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

/// Downloads, verifies, assembles, and installs one catalog package.
public struct ASRModelDownloader: Sendable {
  private let entry: ASRModelCatalogEntry
  private let store: ASRModelPackageStore
  private let fetcher: any ASRModelFileFetching

  public init(
    entry: ASRModelCatalogEntry,
    store: ASRModelPackageStore,
    fetcher: any ASRModelFileFetching = URLSessionModelFileFetcher()
  ) {
    self.entry = entry
    self.store = store
    self.fetcher = fetcher
  }

  public func download(
    progress: @escaping @Sendable (ASRModelDownloadProgress) -> Void
  ) async throws(ASRModelDownloadError) -> InstalledASRModelPackage {
    let fileManager = FileManager.default
    let staging = store.root.appending(
      path: ".staging_\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    defer { try? fileManager.removeItem(at: staging) }
    do {
      try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    } catch {
      throw .installFailed(error.localizedDescription)
    }
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
      return try store.install(movingFrom: staging)
    } catch {
      throw .installFailed("\(error)")
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
