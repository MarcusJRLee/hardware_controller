import Foundation
import HardwareControllerCore
import HardwareControllerMac
import HardwareControllerModelDownload
import Observation

/// Owns the speech engine choice, its Model package, and the download.
///
/// transcribe.cpp is the default. Until its package is installed every
/// Dictation start is refused, so a skipped setup step can never silently
/// leave the user on the less accurate Apple recognizer (docs/decisions/asr_runtime.md).
@MainActor
@Observable
final class SpeechEngineModel {
  enum DownloadState: Equatable {
    case idle
    case downloading(ASRModelDownloadProgress)
    case failed(String)
  }

  private(set) var selection: SpeechEngine
  private(set) var installedPackage: InstalledASRModelPackage?
  private(set) var downloadState = DownloadState.idle

  @ObservationIgnored private let store: ASRModelPackageStore?
  @ObservationIgnored private let catalog: ASRModelCatalogEntry?
  @ObservationIgnored private let fetcher: any ASRModelFileFetching
  @ObservationIgnored private let persist: (SpeechEngine) -> Bool
  @ObservationIgnored private var apply: (SpeechEngineConfiguration) -> Void = { _ in }
  @ObservationIgnored private var downloadTask: Task<Void, Never>?

  init(
    selection: SpeechEngine,
    store: ASRModelPackageStore?,
    catalog: ASRModelCatalogEntry? = ASRModelCatalog.parakeetV3,
    fetcher: any ASRModelFileFetching = URLSessionModelFileFetcher(),
    persist: @escaping (SpeechEngine) -> Bool
  ) {
    self.selection = selection
    self.store = store
    self.catalog = catalog
    self.fetcher = fetcher
    self.persist = persist
    installedPackage = store?.installed()
  }

  /// Installs the process callback after composition; it receives every change.
  func connect(_ apply: @escaping (SpeechEngineConfiguration) -> Void) {
    self.apply = apply
  }

  var configuration: SpeechEngineConfiguration {
    SpeechEngineConfiguration(selection: selection, package: installedPackage)
  }

  var requiresSetup: Bool {
    configuration.requiresSetup
  }

  var isDownloading: Bool {
    if case .downloading = downloadState {
      return true
    }
    return false
  }

  var downloadSize: String {
    ByteCountFormatter.string(fromByteCount: catalog?.downloadBytes ?? 0, countStyle: .file)
  }

  var modelName: String {
    installedPackage?.displayName ?? catalog?.displayName ?? "Parakeet"
  }

  func select(_ engine: SpeechEngine) {
    guard engine != selection, persist(engine) else {
      return
    }
    selection = engine
    apply(configuration)
  }

  func startDownload() {
    guard !isDownloading else {
      return
    }
    guard let store, let catalog else {
      downloadState = .failed("Speech model storage is unavailable.")
      return
    }
    let downloader = ASRModelDownloader(entry: catalog, store: store, fetcher: fetcher)
    downloadState = .downloading(
      ASRModelDownloadProgress(receivedBytes: 0, totalBytes: catalog.downloadBytes))
    // Progress crosses from the download's threads through a stream, so only
    // the main actor ever touches this model.
    let (progress, reporter) = AsyncStream<ASRModelDownloadProgress>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    downloadTask = Task { [weak self] in
      let updates = Task { [weak self] in
        for await value in progress {
          self?.showProgress(value)
        }
      }
      defer { updates.cancel() }
      do throws(ASRModelDownloadError) {
        let installed = try await downloader.download { reporter.yield($0) }
        reporter.finish()
        self?.finishDownload(installed)
      } catch {
        reporter.finish()
        self?.failDownload(error)
      }
    }
  }

  func cancelDownload() {
    downloadTask?.cancel()
    downloadTask = nil
    downloadState = .idle
  }

  func removeModel() {
    guard let store else {
      return
    }
    do {
      try store.removeAll()
    } catch {
      downloadState = .failed("\(error)")
    }
    installedPackage = store.installed()
    apply(configuration)
  }

  private func showProgress(_ progress: ASRModelDownloadProgress) {
    if isDownloading {
      downloadState = .downloading(progress)
    }
  }

  private func finishDownload(_ package: InstalledASRModelPackage) {
    downloadTask = nil
    downloadState = .idle
    installedPackage = package
    apply(configuration)
  }

  private func failDownload(_ error: ASRModelDownloadError) {
    downloadTask = nil
    downloadState =
      switch error {
      case .cancelled:
        .idle
      case .catalogUnavailable:
        .failed("The speech model is not available in this build.")
      case .transferFailed(let message):
        .failed("The download failed: \(message)")
      case .integrityMismatch(let file):
        .failed("\(file) did not match its verified fingerprint, so nothing was installed.")
      case .installFailed(let message):
        .failed("The speech model could not be installed: \(message)")
      }
  }
}
