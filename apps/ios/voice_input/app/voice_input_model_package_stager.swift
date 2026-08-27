import Foundation
import HardwareControllerVoiceFFI

enum VoiceInputModelPackageInstallError: Error, Equatable, LocalizedError, Sendable {
  case invalidSource
  case sourceLimitExceeded
  case libraryLimitExceeded
  case sourceInventoryInvalid
  case validation(PortableVoiceValidationError)
  case identityConflict
  case inputOutputFailure

  var errorDescription: String? {
    switch self {
    case .invalidSource:
      "Choose a readable Model package folder."
    case .sourceLimitExceeded:
      "The Model package exceeds its configured file or byte limit."
    case .libraryLimitExceeded:
      "The local Model library has reached its configured package or byte limit."
    case .sourceInventoryInvalid:
      "The Model package contains an unsupported file, directory, or link."
    case .validation:
      "The Model package failed local integrity validation."
    case .identityConflict:
      "A different Model package already uses this identifier and version."
    case .inputOutputFailure:
      "The Model package could not be copied into private local storage."
    }
  }
}

struct VoiceInputModelPackageStager: Sendable {
  let limits: PortableModelPackageLimits

  func copy(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    do {
      let rootValues: URLResourceValues
      do {
        rootValues = try source.resourceValues(forKeys: [
          .isDirectoryKey,
          .isSymbolicLinkKey,
        ])
      } catch {
        throw VoiceInputModelPackageInstallError.invalidSource
      }
      guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
        throw VoiceInputModelPackageInstallError.invalidSource
      }
      guard
        let enumerator = fileManager.enumerator(
          at: source,
          includingPropertiesForKeys: Self.resourceKeys,
          options: []
        )
      else {
        throw VoiceInputModelPackageInstallError.invalidSource
      }

      try fileManager.createDirectory(
        at: destination,
        withIntermediateDirectories: false
      )
      try protect(destination)
      var entryCount: UInt64 = 0
      var fileCount: UInt64 = 0
      var totalBytes: UInt64 = 0
      let maximumFiles = UInt64(limits.maximumFileCount).saturatingAdd(1)
      let maximumEntries = maximumFiles.saturatingMultiply(2).saturatingAdd(1)
      let maximumBytes = limits.maximumInstalledBytes.saturatingAdd(
        limits.maximumManifestBytes
      )

      while let item = enumerator.nextObject() as? URL {
        entryCount = entryCount.saturatingAdd(1)
        guard entryCount <= maximumEntries else {
          throw VoiceInputModelPackageInstallError.sourceLimitExceeded
        }
        let values = try item.resourceValues(forKeys: Set(Self.resourceKeys))
        let relativeComponents = item.pathComponents.dropFirst(source.pathComponents.count)
        guard !relativeComponents.isEmpty else {
          throw VoiceInputModelPackageInstallError.sourceInventoryInvalid
        }
        let target = relativeComponents.reduce(destination) { partial, component in
          partial.appendingPathComponent(component)
        }
        if values.isSymbolicLink == true {
          enumerator.skipDescendants()
          throw VoiceInputModelPackageInstallError.sourceInventoryInvalid
        }
        if values.isDirectory == true {
          try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
          try protect(target)
          continue
        }
        guard
          values.isRegularFile == true,
          let fileSize = values.fileSize,
          fileSize >= 0
        else {
          throw VoiceInputModelPackageInstallError.sourceInventoryInvalid
        }
        fileCount = fileCount.saturatingAdd(1)
        totalBytes = totalBytes.saturatingAdd(UInt64(fileSize))
        guard fileCount <= maximumFiles, totalBytes <= maximumBytes else {
          throw VoiceInputModelPackageInstallError.sourceLimitExceeded
        }
        try fileManager.copyItem(at: item, to: target)
        let copiedValues = try target.resourceValues(forKeys: [
          .isRegularFileKey,
          .isSymbolicLinkKey,
        ])
        guard
          copiedValues.isRegularFile == true,
          copiedValues.isSymbolicLink != true
        else {
          throw VoiceInputModelPackageInstallError.sourceInventoryInvalid
        }
        try protect(target)
      }
    } catch {
      if fileManager.fileExists(atPath: destination.path) {
        do {
          try fileManager.removeItem(at: destination)
        } catch {
          throw VoiceInputModelPackageInstallError.inputOutputFailure
        }
      }
      if let installError = error as? VoiceInputModelPackageInstallError {
        throw installError
      }
      throw VoiceInputModelPackageInstallError.inputOutputFailure
    }
  }

  private static let resourceKeys: [URLResourceKey] = [
    .fileSizeKey,
    .isDirectoryKey,
    .isRegularFileKey,
    .isSymbolicLinkKey,
  ]

  private func protect(_ url: URL) throws {
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: url.path
    )
  }
}

extension UInt64 {
  fileprivate func saturatingAdd(_ other: UInt64) -> UInt64 {
    let (result, overflow) = addingReportingOverflow(other)
    return overflow ? .max : result
  }

  fileprivate func saturatingMultiply(_ other: UInt64) -> UInt64 {
    let (result, overflow) = multipliedReportingOverflow(by: other)
    return overflow ? .max : result
  }
}
