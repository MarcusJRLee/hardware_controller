import Foundation
import HardwareControllerVoiceFFI

enum VoiceInputASRModelRegistryError: Error, LocalizedError, Sendable {
  case incompatiblePackage
  case packageNotInstalled
  case noSelection
  case invalidSelection
  case inputOutputFailure

  var errorDescription: String? {
    switch self {
    case .incompatiblePackage:
      "Choose a whisper.cpp speech-to-text package that supports completed audio files."
    case .packageNotInstalled:
      "The selected speech-to-text package is no longer installed."
    case .noSelection:
      "Choose a local speech-to-text model before recording."
    case .invalidSelection:
      "The saved speech-to-text model selection is invalid. Choose the model again."
    case .inputOutputFailure:
      "The local speech-to-text model selection could not be saved."
    }
  }
}

protocol VoiceInputASRModelProviding: Sendable {
  func selectedASRModel() async throws -> VoiceInputInstalledModelPackage
}

protocol VoiceInputModelManaging: VoiceInputModelPackageInstalling,
  VoiceInputASRModelProviding
{
  func selectASRModel(_ installed: VoiceInputInstalledModelPackage) async throws
}

actor VoiceInputASRModelRegistry: VoiceInputModelManaging {
  private let installer: VoiceInputModelPackageInstaller
  private let selectionURL: URL

  init(installer: VoiceInputModelPackageInstaller, selectionURL: URL) {
    self.installer = installer
    self.selectionURL = selectionURL
  }

  func install(
    from source: URL,
    expectedManifestSHA256: Data?
  ) async throws -> VoiceInputInstalledModelPackage {
    try await installer.install(
      from: source,
      expectedManifestSHA256: expectedManifestSHA256
    )
  }

  func installedPackages() async throws -> [VoiceInputInstalledModelPackage] {
    try await installer.installedPackages()
  }

  func remove(_ installed: VoiceInputInstalledModelPackage) async throws {
    let selection = try readSelection()
    try await installer.remove(installed)
    guard let selection, selection.matches(installed) else {
      return
    }
    try removeSelection()
  }

  func selectASRModel(_ installed: VoiceInputInstalledModelPackage) async throws {
    guard Self.isCompatible(installed.package) else {
      throw VoiceInputASRModelRegistryError.incompatiblePackage
    }
    let packages = try await installer.installedPackages()
    guard packages.contains(installed) else {
      throw VoiceInputASRModelRegistryError.packageNotInstalled
    }
    try writeSelection(Selection(installed: installed))
  }

  func selectedASRModel() async throws -> VoiceInputInstalledModelPackage {
    guard let selection = try readSelection() else {
      throw VoiceInputASRModelRegistryError.noSelection
    }
    let packages = try await installer.installedPackages()
    guard let installed = packages.first(where: selection.matches) else {
      throw VoiceInputASRModelRegistryError.packageNotInstalled
    }
    guard Self.isCompatible(installed.package) else {
      throw VoiceInputASRModelRegistryError.invalidSelection
    }
    return installed
  }

  private static func isCompatible(_ package: PortableModelPackage) -> Bool {
    package.runtime == .whisperCPP
      && package.stage == .asr
      && package.capabilities.contains(.fileASR)
  }

  private func writeSelection(_ selection: Selection) throws {
    do {
      try FileManager.default.createDirectory(
        at: selectionURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try JSONEncoder().encode(selection)
      try data.write(
        to: selectionURL,
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
      )
    } catch {
      throw VoiceInputASRModelRegistryError.inputOutputFailure
    }
  }

  private func readSelection() throws -> Selection? {
    guard FileManager.default.fileExists(atPath: selectionURL.path) else {
      return nil
    }
    do {
      let selection = try JSONDecoder().decode(
        Selection.self,
        from: Data(contentsOf: selectionURL)
      )
      guard
        selection.schemaRevision == Selection.currentSchemaRevision,
        selection.manifestSHA256.count == 32,
        !selection.packageID.isEmpty,
        !selection.version.isEmpty
      else {
        throw VoiceInputASRModelRegistryError.invalidSelection
      }
      return selection
    } catch let error as VoiceInputASRModelRegistryError {
      throw error
    } catch {
      throw VoiceInputASRModelRegistryError.invalidSelection
    }
  }

  private func removeSelection() throws {
    do {
      if FileManager.default.fileExists(atPath: selectionURL.path) {
        try FileManager.default.removeItem(at: selectionURL)
      }
    } catch {
      throw VoiceInputASRModelRegistryError.inputOutputFailure
    }
  }

  private struct Selection: Codable, Sendable {
    static let currentSchemaRevision = 1

    let schemaRevision: Int
    let packageID: String
    let version: String
    let manifestSHA256: Data

    init(installed: VoiceInputInstalledModelPackage) {
      schemaRevision = Self.currentSchemaRevision
      packageID = installed.package.packageID
      version = installed.package.version
      manifestSHA256 = installed.package.manifestSHA256
    }

    func matches(_ installed: VoiceInputInstalledModelPackage) -> Bool {
      packageID == installed.package.packageID
        && version == installed.package.version
        && manifestSHA256 == installed.package.manifestSHA256
    }
  }
}
