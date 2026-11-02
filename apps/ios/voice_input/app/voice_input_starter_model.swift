import Foundation

/// The speech model shipped inside the app, so a fresh install dictates
/// without preparing a Model package on a Mac.
///
/// The bundled copy still goes through Model-package admission. Its manifest
/// digest is pinned here, so the installer records it as publisher verified and
/// rejects any bundle whose bytes drifted from `scripts/generate_ios_project.sh`.
struct VoiceInputStarterModel: Sendable {
  enum Outcome: Equatable, Sendable {
    /// A speech model was already active or the user owns the choice.
    case unchanged
    case installed
  }

  static let resourceName = "starter_asr_model"
  static let manifestSHA256 = Data(
    [
      0x86, 0xd6, 0x4c, 0x22, 0x7a, 0xd2, 0x4c, 0xb9,
      0xcf, 0xf4, 0x6f, 0x34, 0xf5, 0xa7, 0xbb, 0x47,
      0x6b, 0xbf, 0xe5, 0xc3, 0x24, 0xc7, 0xd1, 0x7f,
      0xc2, 0x1b, 0xac, 0x1e, 0x15, 0x52, 0x3c, 0x25,
    ]
  )

  let packageURL: URL

  init?(bundle: Bundle = .main) {
    guard let url = bundle.url(forResource: Self.resourceName, withExtension: nil) else {
      return nil
    }
    packageURL = url
  }

  init(packageURL: URL) {
    self.packageURL = packageURL
  }

  /// Installs and selects the starter only while the library holds no
  /// compatible speech model; any model the user installed keeps priority.
  func provisionIfNeeded(
    manager: any VoiceInputModelManaging
  ) async throws -> Outcome {
    guard try await !hasActiveModel(manager) else {
      return .unchanged
    }
    let installed = try await manager.installedPackages()
    guard
      !installed.contains(where: {
        VoiceInputASRModelRegistry.isCompatible($0.package)
      })
    else {
      return .unchanged
    }
    let starter = try await manager.install(
      from: packageURL,
      expectedManifestSHA256: Self.manifestSHA256
    )
    try await manager.selectASRModel(starter)
    return .installed
  }

  /// An invalid saved selection still throws: the user must resolve it.
  private func hasActiveModel(_ manager: any VoiceInputModelManaging) async throws -> Bool {
    do {
      _ = try await manager.selectedASRModel()
      return true
    } catch VoiceInputASRModelRegistryError.noSelection,
      VoiceInputASRModelRegistryError.packageNotInstalled
    {
      return false
    }
  }
}
