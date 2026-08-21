import Foundation

public enum ProfileValidationError: Error, Equatable, Sendable {
  case unsupportedSchemaVersion(Int)
  case noProfiles
  case activeProfileMissing
  case emptyProfileName(UUID)
  case duplicateProfileName(String)
  case duplicateProfileID(UUID)
  case duplicateDeviceConfigurationID(UUID)
  case duplicateDeviceMatchRule(
    profileID: UUID,
    matchRule: DeviceMatchRule
  )
  case emptyDeviceModelID(
    profileID: UUID,
    configurationID: UUID
  )
  case emptyStableHardwareID(
    profileID: UUID,
    configurationID: UUID
  )
  case duplicateControlID(
    profileID: UUID,
    configurationID: UUID,
    controlID: ControlID
  )
  case invalidActionConfiguration(
    profileID: UUID,
    configurationID: UUID,
    controlID: ControlID,
    actionKind: ActionKind
  )
  case activationShortcutWithoutAction(
    profileID: UUID,
    configurationID: UUID,
    controlID: ControlID
  )
  case unsafeActivationShortcut(
    profileID: UUID,
    shortcut: KeyboardShortcut
  )
  case duplicateActivationShortcut(
    profileID: UUID,
    shortcut: KeyboardShortcut
  )
  case activationShortcutConflictsWithAction(
    profileID: UUID,
    shortcut: KeyboardShortcut
  )
}

public enum ProfileStoreIssue: Equatable, Sendable {
  case couldNotReadFile(message: String)
  case requiresNewerApp(schemaVersion: Int)
  case recoveredInvalidFile(
    backupURL: URL?,
    backupFailureMessage: String?
  )
  case migratedOwnedDictation
  case migratedDeviceConfigurations
  case migratedKeyboardFallbacks
  case migratedLocalAIDictation
  case migrationNotPersisted(message: String)
}

public struct ProfileLoadResult: Sendable {
  public let envelope: ProfileEnvelope
  public let issue: ProfileStoreIssue?

  public init(envelope: ProfileEnvelope, issue: ProfileStoreIssue?) {
    self.envelope = envelope
    self.issue = issue
  }
}

/// Persists the versioned profile envelope as one atomically replaced JSON file.
public struct ProfileStore: Sendable {
  public let fileURL: URL
  private let fileAccess: any ProfileStoreFileAccessing

  public init(fileURL: URL) {
    self.fileURL = fileURL
    fileAccess = LocalProfileStoreFileAccess()
  }

  init(
    fileURL: URL,
    fileAccess: any ProfileStoreFileAccessing
  ) {
    self.fileURL = fileURL
    self.fileAccess = fileAccess
  }

  public static func applicationSupportStore(
    fileManager: FileManager = .default
  ) throws -> ProfileStore {
    let applicationSupport =
      try ApplicationIdentity.applicationSupportDirectory(
        fileManager: fileManager
      )
    return ProfileStore(
      fileURL:
        applicationSupport
        .appendingPathComponent("profiles.json")
    )
  }

  public func load() -> ProfileLoadResult {
    guard fileAccess.fileExists(at: fileURL) else {
      return ProfileLoadResult(
        envelope: .defaultEnvelope(),
        issue: nil
      )
    }

    let data: Data
    do {
      data = try fileAccess.read(from: fileURL)
    } catch {
      return ProfileLoadResult(
        envelope: .defaultEnvelope(),
        issue: .couldNotReadFile(
          message: error.localizedDescription
        )
      )
    }

    let migration: ProfileMigrationResult
    do {
      migration = try decodeAndMigrate(data)
    } catch ProfileValidationError.unsupportedSchemaVersion(
      let schemaVersion
    ) where schemaVersion > ProfileEnvelope.currentSchemaVersion {
      return ProfileLoadResult(
        envelope: .defaultEnvelope(),
        issue: .requiresNewerApp(schemaVersion: schemaVersion)
      )
    } catch {
      return recoverInvalidFile()
    }

    let envelope = migration.envelope
    do {
      try validate(envelope)
    } catch {
      return recoverInvalidFile()
    }

    guard let migrationIssue = migration.issue else {
      return ProfileLoadResult(
        envelope: envelope,
        issue: nil
      )
    }

    do {
      try save(envelope)
      return ProfileLoadResult(
        envelope: envelope,
        issue: migrationIssue
      )
    } catch {
      return ProfileLoadResult(
        envelope: envelope,
        issue: .migrationNotPersisted(
          message: error.localizedDescription
        )
      )
    }
  }

  public func save(
    _ envelope: ProfileEnvelope
  ) throws {
    try validate(envelope)
    try rejectNewerStoredSchema()
    try fileAccess.createDirectory(
      at: fileURL.deletingLastPathComponent()
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [
      .prettyPrinted,
      .sortedKeys,
      .withoutEscapingSlashes,
    ]
    let data = try encoder.encode(envelope)
    try fileAccess.write(data, to: fileURL)
  }

  public func validate(_ envelope: ProfileEnvelope) throws {
    guard
      envelope.schemaVersion == ProfileEnvelope.currentSchemaVersion
    else {
      throw ProfileValidationError.unsupportedSchemaVersion(
        envelope.schemaVersion
      )
    }

    guard !envelope.profiles.isEmpty else {
      throw ProfileValidationError.noProfiles
    }

    var profileIDs: Set<UUID> = []
    var profileNames: Set<String> = []
    var configurationIDs: Set<UUID> = []
    for profile in envelope.profiles {
      guard profileIDs.insert(profile.id).inserted else {
        throw ProfileValidationError.duplicateProfileID(profile.id)
      }

      let trimmedName = profile.name.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      guard !trimmedName.isEmpty else {
        throw ProfileValidationError.emptyProfileName(profile.id)
      }
      let normalizedName = trimmedName.lowercased()
      guard profileNames.insert(normalizedName).inserted else {
        throw ProfileValidationError.duplicateProfileName(trimmedName)
      }

      let profileBindings = profile.deviceConfigurations.flatMap(\.bindings)
      let actionShortcuts = Set(
        profileBindings.compactMap { binding in
          binding.action.kind == .keyboardShortcut
            ? binding.action.shortcut : nil
        }
      )
      var activationShortcuts: Set<KeyboardShortcut> = []

      var matchRules: Set<DeviceMatchRule> = []
      for configuration in profile.deviceConfigurations {
        guard configurationIDs.insert(configuration.id).inserted else {
          throw
            ProfileValidationError
            .duplicateDeviceConfigurationID(configuration.id)
        }
        guard matchRules.insert(configuration.matchRule).inserted else {
          throw ProfileValidationError.duplicateDeviceMatchRule(
            profileID: profile.id,
            matchRule: configuration.matchRule
          )
        }
        guard
          !configuration.matchRule.modelID.rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        else {
          throw ProfileValidationError.emptyDeviceModelID(
            profileID: profile.id,
            configurationID: configuration.id
          )
        }
        if let stableHardwareID =
          configuration.matchRule.stableHardwareID
        {
          guard
            !stableHardwareID.trimmingCharacters(
              in: .whitespacesAndNewlines
            ).isEmpty
          else {
            throw ProfileValidationError.emptyStableHardwareID(
              profileID: profile.id,
              configurationID: configuration.id
            )
          }
        }

        var controlIDs: Set<ControlID> = []
        for binding in configuration.bindings {
          guard controlIDs.insert(binding.controlID).inserted else {
            throw ProfileValidationError.duplicateControlID(
              profileID: profile.id,
              configurationID: configuration.id,
              controlID: binding.controlID
            )
          }
          guard binding.action.hasValidConfiguration else {
            throw
              ProfileValidationError
              .invalidActionConfiguration(
                profileID: profile.id,
                configurationID: configuration.id,
                controlID: binding.controlID,
                actionKind: binding.action.kind
              )
          }
          if let activationShortcut = binding.activationShortcut {
            guard binding.action.kind != .noAction else {
              throw ProfileValidationError.activationShortcutWithoutAction(
                profileID: profile.id,
                configurationID: configuration.id,
                controlID: binding.controlID
              )
            }
            guard activationShortcut.modifiers.count >= 2 else {
              throw ProfileValidationError.unsafeActivationShortcut(
                profileID: profile.id,
                shortcut: activationShortcut
              )
            }
            guard activationShortcuts.insert(activationShortcut).inserted else {
              throw ProfileValidationError.duplicateActivationShortcut(
                profileID: profile.id,
                shortcut: activationShortcut
              )
            }
            guard !actionShortcuts.contains(activationShortcut) else {
              throw
                ProfileValidationError
                .activationShortcutConflictsWithAction(
                  profileID: profile.id,
                  shortcut: activationShortcut
                )
            }
          }
        }
      }
    }

    guard envelope.activeProfile != nil else {
      throw ProfileValidationError.activeProfileMissing
    }
  }

  private func recoverInvalidFile() -> ProfileLoadResult {
    let backup = preserveInvalidFile()
    return ProfileLoadResult(
      envelope: .defaultEnvelope(),
      issue: .recoveredInvalidFile(
        backupURL: backup.url,
        backupFailureMessage: backup.failureMessage
      )
    )
  }

  /// Prevents an older app from overwriting a newer durable schema.
  private func rejectNewerStoredSchema() throws {
    guard fileAccess.fileExists(at: fileURL) else {
      return
    }
    let data = try fileAccess.read(from: fileURL)
    guard
      let probe = try? JSONDecoder().decode(
        ProfileSchemaVersionProbe.self,
        from: data
      ),
      probe.schemaVersion > ProfileEnvelope.currentSchemaVersion
    else {
      return
    }
    throw ProfileValidationError.unsupportedSchemaVersion(
      probe.schemaVersion
    )
  }

  /// Decodes current data or explicitly migrates one historical schema.
  private func decodeAndMigrate(
    _ data: Data
  ) throws -> ProfileMigrationResult {
    let decoder = JSONDecoder()
    let probe = try decoder.decode(
      ProfileSchemaVersionProbe.self,
      from: data
    )
    switch probe.schemaVersion {
    case ProfileEnvelope.currentSchemaVersion:
      return ProfileMigrationResult(
        envelope: try decoder.decode(ProfileEnvelope.self, from: data),
        issue: nil
      )
    case 4:
      var envelope = try decoder.decode(ProfileEnvelope.self, from: data)
      envelope.schemaVersion = ProfileEnvelope.currentSchemaVersion
      return ProfileMigrationResult(
        envelope: envelope,
        issue: .migratedLocalAIDictation
      )
    case 3:
      var envelope = try decoder.decode(ProfileEnvelope.self, from: data)
      envelope.schemaVersion = ProfileEnvelope.currentSchemaVersion
      return ProfileMigrationResult(
        envelope: envelope,
        issue: .migratedKeyboardFallbacks
      )
    case 1, 2:
      let legacy = try decoder.decode(
        LegacyProfileEnvelope.self,
        from: data
      )
      let profiles = legacy.profiles.map { legacyProfile in
        var bindings = legacyProfile.bindings
        if probe.schemaVersion == 1 {
          for index in bindings.indices
          where bindings[index].action.kind == .dictation {
            bindings[index].action.shortcut = nil
          }
        }
        return Profile(
          id: legacyProfile.id,
          name: legacyProfile.name,
          deviceConfigurations: [
            ProfileDeviceConfiguration(
              matchRule: DeviceMatchRule(modelID: .vecInfinity3),
              bindings: bindings
            )
          ]
        )
      }
      return ProfileMigrationResult(
        envelope: ProfileEnvelope(
          activeProfileID: legacy.activeProfileID,
          profiles: profiles
        ),
        issue:
          probe.schemaVersion == 1
          ? .migratedOwnedDictation
          : .migratedDeviceConfigurations
      )
    default:
      throw ProfileValidationError.unsupportedSchemaVersion(
        probe.schemaVersion
      )
    }
  }

  private func preserveInvalidFile() -> (
    url: URL?,
    failureMessage: String?
  ) {
    let directory = fileURL.deletingLastPathComponent()
    let stem = fileURL.deletingPathExtension().lastPathComponent
    let backupURL = directory.appendingPathComponent(
      "\(stem).corrupt-\(UUID().uuidString.lowercased()).json"
    )

    do {
      try fileAccess.copyItem(
        at: fileURL,
        to: backupURL
      )
      return (backupURL, nil)
    } catch {
      return (nil, error.localizedDescription)
    }
  }
}

extension ProfileValidationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .unsupportedSchemaVersion(let schemaVersion):
      if schemaVersion > ProfileEnvelope.currentSchemaVersion {
        "This Profile file was created by a newer version of Hardware Controller."
      } else {
        "This Profile file uses an unsupported format."
      }
    case .activationShortcutWithoutAction:
      "Choose an Action before adding a keyboard fallback."
    case .unsafeActivationShortcut:
      "Keyboard fallbacks require at least two modifier keys."
    case .duplicateActivationShortcut:
      "Each keyboard fallback in a Profile must be unique."
    case .activationShortcutConflictsWithAction:
      "A keyboard fallback cannot match a Keyboard Shortcut Action in the same Profile."
    default:
      "The Profile contains invalid or conflicting configuration."
    }
  }
}

/// Reads the schema discriminator before choosing one exact decoder.
private struct ProfileSchemaVersionProbe: Decodable {
  let schemaVersion: Int
}

/// Describes one successful current decode or historical migration.
private struct ProfileMigrationResult {
  let envelope: ProfileEnvelope
  let issue: ProfileStoreIssue?
}

/// Decodes the global-Binding shape used by schemas 1 and 2.
private struct LegacyProfileEnvelope: Decodable {
  let activeProfileID: UUID
  let profiles: [LegacyProfile]
}

/// Decodes one historical Profile without leaking it into current domain APIs.
private struct LegacyProfile: Decodable {
  let id: UUID
  let name: String
  let bindings: [Binding]
}

extension ActionConfiguration {
  fileprivate var hasValidConfiguration: Bool {
    switch kind {
    case .noAction, .dictation, .localAIDictation:
      shortcut == nil
    case .keyboardShortcut:
      shortcut != nil
    }
  }
}

protocol ProfileStoreFileAccessing: Sendable {
  func fileExists(at url: URL) -> Bool
  func read(from url: URL) throws -> Data
  func createDirectory(at url: URL) throws
  func write(_ data: Data, to url: URL) throws
  func copyItem(at source: URL, to destination: URL) throws
}

private struct LocalProfileStoreFileAccess:
  ProfileStoreFileAccessing
{
  func fileExists(at url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  func read(from url: URL) throws -> Data {
    try Data(contentsOf: url)
  }

  func createDirectory(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
  }

  func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
  }

  func copyItem(at source: URL, to destination: URL) throws {
    try FileManager.default.copyItem(
      at: source,
      to: destination
    )
  }
}
