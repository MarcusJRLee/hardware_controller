import Foundation
import HardwareControllerModelDownload

/// Downloads one pinned catalog package into private staging, then admits it
/// through the normal Rust-validated installer as publisher verified.
struct VoiceInputModelDownloader: Sendable {
  let stagingRoot: URL
  let manager: any VoiceInputModelManaging
  let fetcher: any ASRModelFileFetching

  init(
    stagingRoot: URL,
    manager: any VoiceInputModelManaging,
    fetcher: any ASRModelFileFetching = URLSessionModelFileFetcher()
  ) {
    self.stagingRoot = stagingRoot
    self.manager = manager
    self.fetcher = fetcher
  }

  func download(
    _ entry: ASRModelCatalogEntry,
    progress: @escaping @Sendable (ASRModelDownloadProgress) -> Void
  ) async throws -> VoiceInputInstalledModelPackage {
    let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    // Partial model bytes are never worth backing up.
    var excluded = stagingRoot
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excluded.setResourceValues(values)
    let manifestSHA256 = try await ASRModelPackageAssembler(entry: entry, fetcher: fetcher)
      .assemble(in: staging, progress: progress)
    return try await manager.install(from: staging, expectedManifestSHA256: manifestSHA256)
  }
}

extension VoiceInputModelDownloader {
  /// User-facing text; the shared error type stays free of iOS copy.
  static func message(for error: any Error) -> String {
    guard let error = error as? ASRModelDownloadError else {
      return error.localizedDescription
    }
    switch error {
    case .catalogUnavailable:
      return "This model is unavailable in this build."
    case .transferFailed(let reason):
      return "The download stopped. \(reason) Check the connection and try again."
    case .integrityMismatch(let file):
      return "\(file) did not match its pinned checksum, so nothing was installed."
    case .installFailed(let reason):
      return "The model could not be installed. \(reason)"
    case .cancelled:
      return "The download was cancelled."
    }
  }
}
