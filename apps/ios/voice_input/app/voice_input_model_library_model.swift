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
  @Published private(set) var isImporting = false
  @Published private(set) var isRemoving = false
  @Published private(set) var errorMessage: String?

  private let installer: any VoiceInputModelPackageInstalling

  convenience init() {
    guard
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      self.init(installer: UnavailableModelPackageInstaller())
      return
    }
    let root =
      applicationSupport
      .appendingPathComponent(
        "com.longdevity.hardwarecontroller.voiceinput",
        isDirectory: true
      )
      .appendingPathComponent("voice_models", isDirectory: true)
    self.init(installer: VoiceInputModelPackageInstaller(rootURL: root))
  }

  init(installer: any VoiceInputModelPackageInstalling) {
    self.installer = installer
  }

  func refresh() async {
    do {
      packages = try await installer.installedPackages()
      errorMessage = nil
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
      _ = try await installer.install(
        from: source,
        expectedManifestSHA256: nil
      )
      packages = try await installer.installedPackages()
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
      try await installer.remove(installed)
      packages = try await installer.installedPackages()
    } catch {
      errorMessage = error.localizedDescription
      do {
        packages = try await installer.installedPackages()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

private struct UnavailableModelPackageInstaller: VoiceInputModelPackageInstalling {
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
}
