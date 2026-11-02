import Foundation
import HardwareControllerModelDownload

/// Downloads one catalog package and installs it as the Mac's single
/// transcribe.cpp package.
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
    _ = try await ASRModelPackageAssembler(entry: entry, fetcher: fetcher)
      .assemble(in: staging, progress: progress)
    do {
      return try store.install(movingFrom: staging)
    } catch {
      throw .installFailed("\(error)")
    }
  }
}
