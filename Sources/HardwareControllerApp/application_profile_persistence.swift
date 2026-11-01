import Foundation
import HardwareControllerCore

/// Isolates Profile persistence from application orchestration.
protocol ProfilePersisting: Sendable {
  /// Loads the current Profile envelope and any recoverable issue.
  func load() -> ProfileLoadResult

  /// Persists one validated Profile envelope atomically.
  func save(_ envelope: ProfileEnvelope) throws
}

extension ProfileStore: ProfilePersisting {}

/// Keeps deterministic previews isolated from the user's persisted Profile.
struct PreviewProfileStore: ProfilePersisting {
  /// Returns the preview's fixed default configuration.
  func load() -> ProfileLoadResult {
    ProfileLoadResult(
      envelope: .defaultEnvelope(),
      issue: nil
    )
  }

  /// Accepts preview-only edits without writing outside the process.
  func save(_ envelope: ProfileEnvelope) throws {}
}

/// Fails explicitly when Profile storage or identity migration is unavailable.
struct UnavailableProfileStore: ProfilePersisting {
  let error: any Error & Sendable

  /// Reports the construction failure without touching local data.
  func load() -> ProfileLoadResult {
    ProfileLoadResult(
      envelope: .defaultEnvelope(),
      issue: .couldNotReadFile(message: error.localizedDescription)
    )
  }

  /// Preserves the original construction failure.
  func save(_ envelope: ProfileEnvelope) throws {
    throw error
  }
}
