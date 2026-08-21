import Foundation
import Testing

@testable import HardwareControllerCore

struct ApplicationIdentityTests {
  /// Keeps the public bundle identifier stable across packaging and storage.
  @Test
  func exposesLongdevityBundleIdentifier() {
    #expect(
      ApplicationIdentity.bundleIdentifier
        == "com.longdevity.hardwarecontroller"
    )
  }

  /// Resolves the public namespace without creating an absent directory.
  @Test(arguments: [false, true])
  func resolvesLongdevityApplicationSupportDirectory(
    directoryExists: Bool
  ) throws {
    try withTemporaryDirectory { root in
      let expected = root.appendingPathComponent(
        ApplicationIdentity.bundleIdentifier,
        isDirectory: true
      )
      if directoryExists {
        try FileManager.default.createDirectory(
          at: expected,
          withIntermediateDirectories: false
        )
      }

      let current = try ApplicationIdentity.applicationSupportDirectory(
        in: root,
        fileManager: .default
      )

      #expect(current == expected)
      #expect(
        FileManager.default.fileExists(
          atPath: current.path
        ) == directoryExists
      )
    }
  }

  /// Rejects a file that occupies the required directory path.
  @Test
  func rejectsNonDirectoryApplicationSupportPath() throws {
    try withTemporaryDirectory { root in
      let current = root.appendingPathComponent(
        ApplicationIdentity.bundleIdentifier
      )
      try Data().write(to: current)

      do {
        _ = try ApplicationIdentity.applicationSupportDirectory(
          in: root,
          fileManager: .default
        )
        Issue.record("Expected a non-directory path failure.")
      } catch ApplicationIdentityError.expectedDirectory(let url) {
        #expect(url.path == current.path)
      }
    }
  }

  private func withTemporaryDirectory(
    _ body: (URL) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    try body(directory)
  }
}
