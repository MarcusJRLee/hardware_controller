import Foundation
import HardwareControllerVoiceFFI

struct VoiceInputInstalledModelPackage: Equatable, Sendable {
  let package: PortableModelPackage
  let rootURL: URL
  let publisherVerified: Bool
}

struct VoiceInputModelLibraryLimits: Equatable, Sendable {
  static let standard = VoiceInputModelLibraryLimits(
    maximumStoredBytes: 12 * 1_024 * 1_024 * 1_024,
    maximumPackageVersions: 8
  )

  let maximumStoredBytes: UInt64
  let maximumPackageVersions: UInt32
}

actor VoiceInputModelPackageInstaller {
  private let rootURL: URL
  private let limits: PortableModelPackageLimits
  private let libraryLimits: VoiceInputModelLibraryLimits
  private let validator = RustPortableVoiceValidator()
  private let stager: VoiceInputModelPackageStager

  init(
    rootURL: URL,
    limits: PortableModelPackageLimits = .standardModelPackage,
    libraryLimits: VoiceInputModelLibraryLimits = .standard
  ) {
    self.rootURL = rootURL
    self.limits = limits
    self.libraryLimits = libraryLimits
    stager = VoiceInputModelPackageStager(limits: limits)
  }

  func install(
    from source: URL,
    expectedManifestSHA256: Data?
  ) throws -> VoiceInputInstalledModelPackage {
    try prepareDirectories()
    let stagingURL = stagingRoot.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    do {
      try stager.copy(from: source, to: stagingURL)
      let package = try validator.validateModelPackage(
        at: stagingURL,
        limits: limits,
        expectedManifestSHA256: expectedManifestSHA256
      )
      let destination = installedURL(for: package)
      if FileManager.default.fileExists(atPath: destination.path) {
        let existing = try validatedPackage(at: destination)
        guard existing.manifestSHA256 == package.manifestSHA256 else {
          throw VoiceInputModelPackageInstallError.identityConflict
        }
        try remove(stagingURL)
        if expectedManifestSHA256 != nil {
          try writeRecord(for: existing, publisherVerified: true)
        }
        return try installedPackage(for: existing, at: destination)
      }

      try enforceLibraryLimits(adding: package)

      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.moveItem(at: stagingURL, to: destination)
      do {
        try writeRecord(
          for: package,
          publisherVerified: expectedManifestSHA256 != nil
        )
      } catch {
        try remove(destination)
        throw error
      }
      return try installedPackage(for: package, at: destination)
    } catch {
      if FileManager.default.fileExists(atPath: stagingURL.path) {
        do {
          try remove(stagingURL)
        } catch {
          throw VoiceInputModelPackageInstallError.inputOutputFailure
        }
      }
      throw Self.installError(error)
    }
  }

  func installedPackages() throws -> [VoiceInputInstalledModelPackage] {
    try prepareDirectories()
    return try loadInstalledPackages()
  }

  func remove(_ installed: VoiceInputInstalledModelPackage) throws {
    try prepareDirectories()
    let destination = installedURL(for: installed.package)
    guard
      destination.standardizedFileURL == installed.rootURL.standardizedFileURL,
      FileManager.default.fileExists(atPath: destination.path)
    else {
      throw VoiceInputModelPackageInstallError.identityConflict
    }
    let current = try validatedPackage(at: destination)
    guard current.manifestSHA256 == installed.package.manifestSHA256 else {
      throw VoiceInputModelPackageInstallError.identityConflict
    }
    let quarantine = stagingRoot.appendingPathComponent(
      "removal-\(UUID().uuidString)",
      isDirectory: true
    )
    do {
      try FileManager.default.moveItem(at: destination, to: quarantine)
    } catch {
      throw VoiceInputModelPackageInstallError.inputOutputFailure
    }
    let record = recordURL(for: current)
    do {
      if FileManager.default.fileExists(atPath: record.path) {
        try remove(record)
      }
    } catch {
      do {
        try FileManager.default.moveItem(at: quarantine, to: destination)
      } catch {
        throw VoiceInputModelPackageInstallError.inputOutputFailure
      }
      throw error
    }
    try remove(quarantine)
  }

  private func loadInstalledPackages() throws -> [VoiceInputInstalledModelPackage] {
    var packages: [VoiceInputInstalledModelPackage] = []
    for packageDirectory in try directoryContents(at: installedRoot) {
      for versionDirectory in try directoryContents(at: packageDirectory) {
        let package = try validatedPackage(at: versionDirectory)
        guard
          package.packageID == packageDirectory.lastPathComponent,
          package.version == versionDirectory.lastPathComponent
        else {
          throw VoiceInputModelPackageInstallError.identityConflict
        }
        packages.append(
          try installedPackage(for: package, at: versionDirectory)
        )
      }
    }
    return packages.sorted {
      ($0.package.stage.rawValue, $0.package.displayName, $0.package.version)
        < ($1.package.stage.rawValue, $1.package.displayName, $1.package.version)
    }
  }

  private func enforceLibraryLimits(adding package: PortableModelPackage) throws {
    let installed = try loadInstalledPackages()
    guard installed.count < Int(libraryLimits.maximumPackageVersions) else {
      throw VoiceInputModelPackageInstallError.libraryLimitExceeded
    }
    var storedBytes: UInt64 = 0
    for current in installed {
      let (sum, overflow) = storedBytes.addingReportingOverflow(
        current.package.verifiedBytes
      )
      guard !overflow else {
        throw VoiceInputModelPackageInstallError.libraryLimitExceeded
      }
      storedBytes = sum
    }
    let (prospectiveBytes, overflow) = storedBytes.addingReportingOverflow(
      package.verifiedBytes
    )
    guard
      !overflow,
      prospectiveBytes <= libraryLimits.maximumStoredBytes
    else {
      throw VoiceInputModelPackageInstallError.libraryLimitExceeded
    }
  }

  private func prepareDirectories() throws {
    do {
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: true
      )
      var protectedRoot = rootURL
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try protectedRoot.setResourceValues(values)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: rootURL.path
      )
      try FileManager.default.createDirectory(
        at: stagingRoot,
        withIntermediateDirectories: true
      )
      try FileManager.default.createDirectory(
        at: installedRoot,
        withIntermediateDirectories: true
      )
      try FileManager.default.createDirectory(
        at: recordsRoot,
        withIntermediateDirectories: true
      )
      for stale in try directoryContents(at: stagingRoot) {
        try remove(stale)
      }
    } catch {
      throw Self.installError(error)
    }
  }

  private func validatedPackage(at url: URL) throws -> PortableModelPackage {
    do {
      return try validator.validateModelPackage(
        at: url,
        limits: limits,
        expectedManifestSHA256: nil
      )
    } catch let error as PortableVoiceValidationError {
      throw VoiceInputModelPackageInstallError.validation(error)
    } catch {
      throw VoiceInputModelPackageInstallError.inputOutputFailure
    }
  }

  private func installedPackage(
    for package: PortableModelPackage,
    at url: URL
  ) throws -> VoiceInputInstalledModelPackage {
    let record = try readRecord(for: package)
    guard record?.manifestSHA256 == nil || record?.manifestSHA256 == package.manifestSHA256
    else {
      throw VoiceInputModelPackageInstallError.identityConflict
    }
    return VoiceInputInstalledModelPackage(
      package: package,
      rootURL: url,
      publisherVerified: record?.publisherVerified ?? false
    )
  }

  private func writeRecord(
    for package: PortableModelPackage,
    publisherVerified: Bool
  ) throws {
    let url = recordURL(for: package)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let record = InstallRecord(
      schemaRevision: InstallRecord.currentSchemaRevision,
      manifestSHA256: package.manifestSHA256,
      publisherVerified: publisherVerified
    )
    let data = try JSONEncoder().encode(record)
    try data.write(
      to: url,
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    )
  }

  private func readRecord(for package: PortableModelPackage) throws -> InstallRecord? {
    do {
      let url = recordURL(for: package)
      guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
      }
      let record = try JSONDecoder().decode(
        InstallRecord.self,
        from: Data(contentsOf: url)
      )
      guard record.schemaRevision == InstallRecord.currentSchemaRevision else {
        throw VoiceInputModelPackageInstallError.inputOutputFailure
      }
      return record
    } catch let error as VoiceInputModelPackageInstallError {
      throw error
    } catch {
      throw VoiceInputModelPackageInstallError.inputOutputFailure
    }
  }

  private func installedURL(for package: PortableModelPackage) -> URL {
    installedRoot
      .appendingPathComponent(package.packageID, isDirectory: true)
      .appendingPathComponent(package.version, isDirectory: true)
  }

  private func recordURL(for package: PortableModelPackage) -> URL {
    recordsRoot
      .appendingPathComponent(package.packageID, isDirectory: true)
      .appendingPathComponent("\(package.version).json")
  }

  private func directoryContents(at url: URL) throws -> [URL] {
    let contents = try FileManager.default.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    for item in contents {
      let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw VoiceInputModelPackageInstallError.sourceInventoryInvalid
      }
    }
    return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func remove(_ url: URL) throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      throw VoiceInputModelPackageInstallError.inputOutputFailure
    }
  }

  private static func installError(_ error: Error) -> VoiceInputModelPackageInstallError {
    if let installError = error as? VoiceInputModelPackageInstallError {
      return installError
    }
    if let validationError = error as? PortableVoiceValidationError {
      return .validation(validationError)
    }
    return .inputOutputFailure
  }

  private var stagingRoot: URL {
    rootURL.appendingPathComponent("staging", isDirectory: true)
  }

  private var installedRoot: URL {
    rootURL.appendingPathComponent("installed", isDirectory: true)
  }

  private var recordsRoot: URL {
    rootURL.appendingPathComponent("records", isDirectory: true)
  }

  private struct InstallRecord: Codable {
    static let currentSchemaRevision = 1

    let schemaRevision: Int
    let manifestSHA256: Data
    let publisherVerified: Bool
  }
}
