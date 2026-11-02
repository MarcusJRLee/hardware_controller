import Combine
import Foundation
import HardwareControllerModelDownload

protocol VoiceInputModelPackageInstalling: Sendable {
  func install(
    from source: URL,
    expectedManifestSHA256: Data?
  ) async throws -> VoiceInputInstalledModelPackage

  func installedPackages() async throws -> [VoiceInputInstalledModelPackage]

  func remove(_ installed: VoiceInputInstalledModelPackage) async throws
}

extension VoiceInputModelPackageInstaller: VoiceInputModelPackageInstalling {}

@MainActor
final class VoiceInputModelLibraryModel: ObservableObject {
  @Published private(set) var packages: [VoiceInputInstalledModelPackage] = []
  @Published private(set) var activeASRModel: VoiceInputInstalledModelPackage?
  @Published private(set) var isImporting = false
  @Published private(set) var isRemoving = false
  @Published private(set) var isPreparingStarter = false
  /// Download progress from 0 to 1, keyed by catalog package ID.
  @Published private(set) var downloads: [String: Double] = [:]
  @Published private(set) var errorMessage: String?

  let catalog: [ASRModelCatalogEntry]
  private let manager: any VoiceInputModelManaging
  private let asrWorkflow: VoiceInputASRWorkflow?
  private let starter: VoiceInputStarterModel?
  private let downloader: VoiceInputModelDownloader?
  private var downloadTasks: [String: Task<Void, Never>] = [:]
  /// Provisioning runs once per launch, so removing the starter is not undone
  /// until the next launch finds the library without a speech model.
  private var starterProvisioningAttempted = false

  convenience init() {
    guard
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      self.init(manager: UnavailableModelManager())
      return
    }
    let root =
      applicationSupport
      .appendingPathComponent(
        "com.longdevity.hardwarecontroller.voiceinput",
        isDirectory: true
      )
      .appendingPathComponent("voice_models", isDirectory: true)
    let installer = VoiceInputModelPackageInstaller(rootURL: root)
    self.init(
      manager: VoiceInputASRModelRegistry(
        installer: installer,
        selectionURL: root.appendingPathComponent("active_asr.json")
      )
    )
  }

  init(
    manager: any VoiceInputModelManaging,
    asrWorkflow: VoiceInputASRWorkflow? = nil,
    starter: VoiceInputStarterModel? = nil,
    downloader: VoiceInputModelDownloader? = nil,
    catalog: [ASRModelCatalogEntry] = ASRModelCatalog.voiceInputDownloads
  ) {
    self.manager = manager
    self.asrWorkflow = asrWorkflow
    self.starter = starter
    self.downloader = downloader
    self.catalog = downloader == nil ? [] : catalog
  }

  var choices: [VoiceInputModelChoice] {
    VoiceInputModelChoice.choices(
      installed: packages,
      active: activeASRModel,
      catalog: catalog,
      downloads: downloads
    )
  }

  /// Downloads, verifies, installs, and then activates one catalog package,
  /// as on the Mac: the user asked for it, so it becomes the speech model.
  func download(_ entry: ASRModelCatalogEntry) {
    guard let downloader, downloads[entry.packageID] == nil else {
      return
    }
    downloads[entry.packageID] = 0
    errorMessage = nil
    // Progress arrives on the download's threads; a stream keeps every
    // published change on the main actor.
    let (progress, reporter) = AsyncStream<Double>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    downloadTasks[entry.packageID] = Task { [weak self] in
      let updates = Task { [weak self] in
        for await fraction in progress {
          self?.showProgress(fraction, for: entry.packageID)
        }
      }
      defer { updates.cancel() }
      do {
        let installed = try await downloader.download(entry) { reporter.yield($0.fraction) }
        reporter.finish()
        await self?.finishDownload(entry.packageID, installed: installed)
      } catch {
        reporter.finish()
        self?.failDownload(entry.packageID, error: error)
      }
    }
  }

  func cancelDownload(_ entry: ASRModelCatalogEntry) {
    downloadTasks.removeValue(forKey: entry.packageID)?.cancel()
    downloads[entry.packageID] = nil
  }

  private func showProgress(_ fraction: Double, for packageID: String) {
    guard downloads[packageID] != nil else {
      return
    }
    downloads[packageID] = fraction
  }

  private func finishDownload(
    _ packageID: String,
    installed: VoiceInputInstalledModelPackage
  ) async {
    downloadTasks[packageID] = nil
    downloads[packageID] = nil
    await refresh()
    await selectASRModel(installed)
  }

  private func failDownload(_ packageID: String, error: any Error) {
    downloadTasks[packageID] = nil
    let wasCancelled = downloads[packageID] == nil || Task.isCancelled
    downloads[packageID] = nil
    if !wasCancelled, (error as? ASRModelDownloadError) != .cancelled {
      errorMessage = VoiceInputModelDownloader.message(for: error)
    }
  }

  func refresh() async {
    let starterError = await provisionStarterOnce()
    do {
      packages = try await manager.installedPackages()
      await refreshSelection()
    } catch {
      errorMessage = error.localizedDescription
    }
    if let starterError {
      errorMessage = starterError
    }
  }

  private func provisionStarterOnce() async -> String? {
    guard let starter, !starterProvisioningAttempted else {
      return nil
    }
    starterProvisioningAttempted = true
    isPreparingStarter = true
    defer { isPreparingStarter = false }
    do {
      _ = try await starter.provisionIfNeeded(manager: manager)
      return nil
    } catch {
      return "The built-in speech model could not be installed. \(error.localizedDescription)"
    }
  }

  func importPackage(from source: URL) async {
    guard !isImporting, !isRemoving else {
      return
    }
    isImporting = true
    errorMessage = nil
    let accessed = source.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        source.stopAccessingSecurityScopedResource()
      }
      isImporting = false
    }
    do {
      _ = try await manager.install(
        from: source,
        expectedManifestSHA256: nil
      )
      packages = try await manager.installedPackages()
      await refreshSelection()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func removePackage(_ installed: VoiceInputInstalledModelPackage) async {
    guard !isImporting, !isRemoving else {
      return
    }
    isRemoving = true
    errorMessage = nil
    defer { isRemoving = false }
    do {
      try await manager.remove(installed)
      packages = try await manager.installedPackages()
      await refreshSelection()
    } catch {
      errorMessage = error.localizedDescription
      do {
        packages = try await manager.installedPackages()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func selectASRModel(_ installed: VoiceInputInstalledModelPackage) async {
    guard !isImporting, !isRemoving else {
      return
    }
    errorMessage = nil
    do {
      try await manager.selectASRModel(installed)
      activeASRModel = try await manager.selectedASRModel()
      try await asrWorkflow?.prewarmSelectedModel()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func isActiveASRModel(_ installed: VoiceInputInstalledModelPackage) -> Bool {
    activeASRModel == installed
  }

  private func refreshSelection() async {
    do {
      activeASRModel = try await manager.selectedASRModel()
      do {
        try await asrWorkflow?.prewarmSelectedModel()
        errorMessage = nil
      } catch {
        errorMessage = error.localizedDescription
      }
    } catch VoiceInputASRModelRegistryError.noSelection {
      activeASRModel = nil
      errorMessage = nil
    } catch VoiceInputASRModelRegistryError.packageNotInstalled {
      activeASRModel = nil
      errorMessage = VoiceInputASRModelRegistryError.packageNotInstalled.localizedDescription
    } catch {
      activeASRModel = nil
      errorMessage = error.localizedDescription
    }
  }
}

struct UnavailableModelManager: VoiceInputModelManaging {
  func install(
    from _: URL,
    expectedManifestSHA256 _: Data?
  ) async throws -> VoiceInputInstalledModelPackage {
    throw VoiceInputModelPackageInstallError.inputOutputFailure
  }

  func installedPackages() async throws -> [VoiceInputInstalledModelPackage] {
    throw VoiceInputModelPackageInstallError.inputOutputFailure
  }

  func remove(_: VoiceInputInstalledModelPackage) async throws {
    throw VoiceInputModelPackageInstallError.inputOutputFailure
  }

  func selectASRModel(_: VoiceInputInstalledModelPackage) async throws {
    throw VoiceInputModelPackageInstallError.inputOutputFailure
  }

  func selectedASRModel() async throws -> VoiceInputInstalledModelPackage {
    throw VoiceInputModelPackageInstallError.inputOutputFailure
  }
}
