import Combine
import Foundation

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
  @Published private(set) var errorMessage: String?

  private let manager: any VoiceInputModelManaging
  private let asrWorkflow: VoiceInputASRWorkflow?

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
    asrWorkflow: VoiceInputASRWorkflow? = nil
  ) {
    self.manager = manager
    self.asrWorkflow = asrWorkflow
  }

  func refresh() async {
    do {
      packages = try await manager.installedPackages()
      await refreshSelection()
    } catch {
      errorMessage = error.localizedDescription
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
