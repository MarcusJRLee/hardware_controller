import Foundation
import HardwareControllerCore
import HardwareControllerVoiceFFI

public enum ASRModelPackageStoreError: Error, Equatable, Sendable {
  /// The package failed Rust validation or is not a transcribe.cpp ASR package.
  case invalidPackage
  case storageUnavailable(String)
}

/// Keeps the one installed transcribe.cpp Model package and its record.
///
/// Installation validates every file with Rust once and records the manifest
/// digest; the service revalidates against that digest before each load.
public struct ASRModelPackageStore: Sendable {
  /// The record format; a newer record is treated as no package, never guessed at.
  static let recordVersion = 1

  private struct Record: Codable {
    let version: Int
    let directoryName: String
    let packageID: String
    let packageVersion: String
    let displayName: String
    let manifestSHA256: Data
  }

  public let root: URL
  private let validate: @Sendable (URL) throws -> PortableModelPackage

  public init(
    root: URL,
    validate: @escaping @Sendable (URL) throws -> PortableModelPackage = { url in
      try RustPortableVoiceValidator().validateModelPackage(
        at: url,
        limits: .standardModelPackage,
        expectedManifestSHA256: nil
      )
    }
  ) {
    self.root = root
    self.validate = validate
  }

  public static func applicationSupport() throws -> ASRModelPackageStore {
    ASRModelPackageStore(
      root: try ApplicationIdentity.applicationSupportDirectory()
        .appending(path: "SpeechModels", directoryHint: .isDirectory)
    )
  }

  private var recordURL: URL {
    root.appending(path: "installed.json")
  }

  /// The installed package, or nil when none is installed or its files are gone.
  public func installed() -> InstalledASRModelPackage? {
    guard
      let data = try? Data(contentsOf: recordURL),
      let record = try? JSONDecoder().decode(Record.self, from: data),
      record.version == Self.recordVersion,
      Self.isSafeDirectoryName(record.directoryName)
    else {
      return nil
    }
    let directory = root.appending(path: record.directoryName, directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: directory.appending(path: "manifest.json").path)
    else {
      return nil
    }
    return InstalledASRModelPackage(
      rootURL: directory,
      packageID: record.packageID,
      version: record.packageVersion,
      displayName: record.displayName,
      manifestSHA256: record.manifestSHA256
    )
  }

  /// Validates `source`, moves it into the store, and replaces any previous package.
  @discardableResult
  public func install(
    movingFrom source: URL
  ) throws(ASRModelPackageStoreError) -> InstalledASRModelPackage {
    let package: PortableModelPackage
    do {
      package = try validate(source)
    } catch {
      throw .invalidPackage
    }
    guard
      package.runtime == .transcribeCPP,
      package.stage == .asr,
      package.capabilities.contains(.fileASR)
    else {
      throw .invalidPackage
    }
    let fileManager = FileManager.default
    let directoryName = "package_\(UUID().uuidString.lowercased())"
    let destination = root.appending(path: directoryName, directoryHint: .isDirectory)
    let previous = installed()
    do {
      try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
      try fileManager.moveItem(at: source, to: destination)
      let record = Record(
        version: Self.recordVersion,
        directoryName: directoryName,
        packageID: package.packageID,
        packageVersion: package.version,
        displayName: package.displayName,
        manifestSHA256: package.manifestSHA256
      )
      // The record switches packages in one atomic rename.
      try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
    } catch {
      try? fileManager.removeItem(at: destination)
      throw .storageUnavailable(
        "The speech model could not be installed: \(error.localizedDescription)")
    }
    if let previous, previous.rootURL != destination {
      try? fileManager.removeItem(at: previous.rootURL)
    }
    return InstalledASRModelPackage(
      rootURL: destination,
      packageID: package.packageID,
      version: package.version,
      displayName: package.displayName,
      manifestSHA256: package.manifestSHA256
    )
  }

  /// Removes the installed package and every stale or partial directory.
  public func removeAll() throws(ASRModelPackageStoreError) {
    do {
      if FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.removeItem(at: root)
      }
    } catch {
      throw .storageUnavailable(
        "The speech model could not be removed: \(error.localizedDescription)")
    }
  }

  /// A record may name only a directory this store created.
  static func isSafeDirectoryName(_ name: String) -> Bool {
    name.hasPrefix("package_") && !name.contains("/") && !name.contains("..")
  }
}
