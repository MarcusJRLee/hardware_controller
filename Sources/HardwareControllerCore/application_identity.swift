import Foundation

/// Centralizes the public application identity and local storage namespace.
public enum ApplicationIdentity {
  public static let bundleIdentifier =
    "com.longdevity.hardwarecontroller"

  /// Resolves the application-owned support directory.
  public static func applicationSupportDirectory(
    fileManager: FileManager = .default
  ) throws -> URL {
    let root = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return try applicationSupportDirectory(
      in: root,
      fileManager: fileManager
    )
  }

  /// Rejects a file where application-owned directory state is required.
  static func applicationSupportDirectory(
    in root: URL,
    fileManager: FileManager
  ) throws -> URL {
    let current = root.appendingPathComponent(
      bundleIdentifier,
      isDirectory: true
    )
    try validateDirectoryIfPresent(
      at: current,
      fileManager: fileManager
    )
    return current
  }

  /// Rejects a file where application-owned directory state is required.
  private static func validateDirectoryIfPresent(
    at url: URL,
    fileManager: FileManager
  ) throws {
    var isDirectory = ObjCBool(false)
    guard
      fileManager.fileExists(
        atPath: url.path,
        isDirectory: &isDirectory
      )
    else {
      return
    }
    guard isDirectory.boolValue else {
      throw ApplicationIdentityError.expectedDirectory(url)
    }
  }
}

/// Describes an invalid local path that blocks application storage.
public enum ApplicationIdentityError:
  Error,
  Equatable,
  LocalizedError,
  Sendable
{
  case expectedDirectory(URL)

  public var errorDescription: String? {
    switch self {
    case .expectedDirectory(let url):
      "Expected a directory at \(url.path)."
    }
  }
}
