import Foundation

public enum ApplicationInstallationLocation:
  Equatable,
  Sendable
{
  case applications
  case diskImage
  case other

  public init(
    bundleURL: URL,
    homeDirectory: URL = FileManager.default
      .homeDirectoryForCurrentUser
  ) {
    let bundlePath = bundleURL.standardizedFileURL.path
    let applicationsPaths = [
      URL(fileURLWithPath: "/Applications").path,
      homeDirectory
        .appendingPathComponent("Applications", isDirectory: true)
        .standardizedFileURL.path,
    ]

    if applicationsPaths.contains(
      where: { bundlePath.hasPathPrefix($0) }
    ) {
      self = .applications
    } else if bundlePath.hasPathPrefix("/Volumes") {
      self = .diskImage
    } else {
      self = .other
    }
  }

  public var requiresInstallation: Bool {
    self == .diskImage
  }

  public var canRegisterLoginItem: Bool {
    self == .applications
  }
}

extension String {
  fileprivate func hasPathPrefix(_ directory: String) -> Bool {
    self == directory || hasPrefix(directory + "/")
  }
}
