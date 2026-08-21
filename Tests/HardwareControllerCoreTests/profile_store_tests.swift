import Foundation
import Testing

@testable import HardwareControllerCore

struct ProfileStoreTests {
  private let infinity = DeviceMatchRule(modelID: .vecInfinity3)

  /// Loads the safe Profile when no durable file exists.
  @Test
  func missingFileLoadsSafeDefault() throws {
    try withStore { store, _ in
      let result = store.load()

      #expect(result.envelope.activeProfile == .defaultProfile)
      #expect(result.issue == nil)
    }
  }

  /// Persists and reloads the complete current envelope.
  @Test
  func roundTripsVersionedMultiProfileEnvelope() throws {
    try withStore { store, _ in
      var first = Profile.defaultProfile
      let configuration = try #require(first.deviceConfigurations.first)
      var center = try #require(configuration.binding(for: .center))
      center.activationShortcut = .suggestedControlActivation
      try first.setBinding(
        center,
        configurationID: configuration.id
      )
      let second = Profile(name: "Logic", deviceConfigurations: [])
      let envelope = ProfileEnvelope(
        activeProfileID: second.id,
        profiles: [first, second]
      )

      try store.save(envelope)
      let result = store.load()

      #expect(result.envelope == envelope)
      #expect(result.issue == nil)
    }
  }

  /// Adds optional fallback storage without activating one during migration.
  @Test
  func migratesSchemaThreeWithoutAddingKeyboardFallbacks() throws {
    try withStore { store, directory in
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      var envelope = ProfileEnvelope.defaultEnvelope()
      envelope.schemaVersion = 3
      try JSONEncoder().encode(envelope).write(to: store.fileURL)

      let result = store.load()

      #expect(result.issue == .migratedKeyboardFallbacks)
      #expect(
        result.envelope.schemaVersion == ProfileEnvelope.currentSchemaVersion
      )
      #expect(
        result.envelope.activeProfile?
          .deviceConfigurations.flatMap(\.bindings)
          .allSatisfy { $0.activationShortcut == nil } == true
      )
    }
  }

  /// Adds the Local AI Action case without changing existing Bindings.
  @Test
  func migratesSchemaFourWithoutChangingActions() throws {
    try withStore { store, directory in
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      var envelope = ProfileEnvelope.defaultEnvelope()
      let actions = envelope.activeProfile?
        .deviceConfigurations.flatMap(\.bindings).map(\.action)
      envelope.schemaVersion = 4
      try JSONEncoder().encode(envelope).write(to: store.fileURL)

      let result = store.load()

      #expect(result.issue == .migratedLocalAIDictation)
      #expect(
        result.envelope.schemaVersion == ProfileEnvelope.currentSchemaVersion
      )
      #expect(
        result.envelope.activeProfile?
          .deviceConfigurations.flatMap(\.bindings).map(\.action)
          == actions
      )
    }
  }

  /// Migrates schema-2 global Bindings into one model setup.
  @Test
  func migratesSchemaTwoBindingsIntoInfinityDeviceSetup() throws {
    try withStore { store, directory in
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let profileID = UUID()
      let bindings = Profile.defaultProfile.deviceConfigurations[0].bindings
      try legacyData(
        schemaVersion: 2,
        profileID: profileID,
        bindings: bindings
      ).write(to: store.fileURL)

      let result = store.load()

      #expect(result.issue == .migratedDeviceConfigurations)
      #expect(
        result.envelope.schemaVersion == ProfileEnvelope.currentSchemaVersion
      )
      #expect(result.envelope.activeProfileID == profileID)
      #expect(
        result.envelope.activeProfile?
          .configuration(matching: infinity)?.bindings == bindings
      )
      let persisted = try JSONDecoder().decode(
        ProfileEnvelope.self,
        from: Data(contentsOf: store.fileURL)
      )
      #expect(persisted == result.envelope)
    }
  }

  /// Migrates schema-1 Dictation ownership and Device structure together.
  @Test
  func migratesSchemaOneDictationAndDeviceSetup() throws {
    try withStore { store, directory in
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let profileID = UUID()
      var bindings = Profile.defaultProfile.deviceConfigurations[0].bindings
      let centerIndex = try #require(
        bindings.firstIndex { $0.controlID == .center }
      )
      bindings[centerIndex].action.shortcut = KeyboardShortcut(
        keyCode: 35,
        modifiers: [.control, .option]
      )
      try legacyData(
        schemaVersion: 1,
        profileID: profileID,
        bindings: bindings
      ).write(to: store.fileURL)

      let result = store.load()

      #expect(result.issue == .migratedOwnedDictation)
      #expect(
        result.envelope.activeProfile?
          .binding(for: .center, matching: infinity)?.action
          == .dictation()
      )
      #expect(
        result.envelope.schemaVersion == ProfileEnvelope.currentSchemaVersion
      )
    }
  }

  /// Keeps a valid migrated envelope usable when its rewrite fails.
  @Test
  func migrationWriteFailureKeepsTheMigratedProfile() throws {
    let profileID = UUID()
    let bindings = Profile.defaultProfile.deviceConfigurations[0].bindings
    let store = ProfileStore(
      fileURL: URL(fileURLWithPath: "/profiles.json"),
      fileAccess: StubProfileStoreFileAccess(
        readResult: .success(
          try legacyData(
            schemaVersion: 2,
            profileID: profileID,
            bindings: bindings
          )
        ),
        writeError: .write
      )
    )

    let result = store.load()

    #expect(
      result.envelope.schemaVersion == ProfileEnvelope.currentSchemaVersion
    )
    #expect(result.envelope.activeProfileID == profileID)
    guard case .migrationNotPersisted = result.issue else {
      Issue.record("Expected a migration persistence failure.")
      return
    }
  }

  /// Preserves corrupt bytes before activating the safe fallback.
  @Test
  func corruptFileIsPreservedBeforeSafeRecovery() throws {
    try withStore { store, directory in
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let invalidData = Data("{ definitely not json".utf8)
      try invalidData.write(to: store.fileURL)

      let result = store.load()

      #expect(result.envelope.activeProfile == .defaultProfile)
      guard
        case .recoveredInvalidFile(let backupURL, nil) = result.issue,
        let backupURL
      else {
        Issue.record("Expected an invalid-file recovery issue.")
        return
      }
      #expect(try Data(contentsOf: backupURL) == invalidData)
      #expect(try Data(contentsOf: store.fileURL) == invalidData)
    }
  }

  /// Requires an app update without misclassifying newer data as corrupt.
  @Test
  func newerSchemaRequiresNewerAppWithoutCorruptBackup() {
    let futureVersion = ProfileEnvelope.currentSchemaVersion + 1
    let store = ProfileStore(
      fileURL: URL(fileURLWithPath: "/profiles.json"),
      fileAccess: StubProfileStoreFileAccess(
        readResult: .success(
          Data("{\"schemaVersion\":\(futureVersion)}".utf8)
        ),
        copyError: .copy
      )
    )

    let result = store.load()

    #expect(result.envelope.activeProfile == .defaultProfile)
    #expect(
      result.issue
        == .requiresNewerApp(schemaVersion: futureVersion)
    )
  }

  /// Prevents an older app from replacing a newer Profile schema.
  @Test
  func newerSchemaCannotBeOverwritten() throws {
    try withStore { store, directory in
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let futureVersion = ProfileEnvelope.currentSchemaVersion + 1
      let futureData = Data(
        "{\"schemaVersion\":\(futureVersion)}".utf8
      )
      try futureData.write(to: store.fileURL)

      #expect(
        throws:
          ProfileValidationError.unsupportedSchemaVersion(
            futureVersion
          )
      ) {
        try store.save(.defaultEnvelope())
      }
      #expect(try Data(contentsOf: store.fileURL) == futureData)
    }
  }

  /// Distinguishes unavailable storage from invalid stored data.
  @Test
  func readFailureIsNotReportedAsCorruption() {
    let store = ProfileStore(
      fileURL: URL(fileURLWithPath: "/profiles.json"),
      fileAccess: StubProfileStoreFileAccess(
        readResult: .failure(.read)
      )
    )

    let result = store.load()

    #expect(result.envelope.activeProfile == .defaultProfile)
    guard case .couldNotReadFile = result.issue else {
      Issue.record("Expected a read failure.")
      return
    }
  }

  @Test
  func backupFailureRemainsVisible() {
    let store = ProfileStore(
      fileURL: URL(fileURLWithPath: "/profiles.json"),
      fileAccess: StubProfileStoreFileAccess(
        readResult: .success(Data("invalid".utf8)),
        copyError: .copy
      )
    )

    let result = store.load()

    guard
      case .recoveredInvalidFile(nil, let backupFailure) = result.issue
    else {
      Issue.record("Expected an invalid-file recovery issue.")
      return
    }
    #expect(backupFailure != nil)
  }

  /// Rejects schema versions this build cannot interpret.
  @Test
  func rejectsUnknownSchemaVersion() throws {
    try withStore { store, _ in
      var envelope = ProfileEnvelope.defaultEnvelope()
      envelope.schemaVersion = 999

      #expect(
        throws: ProfileValidationError.unsupportedSchemaVersion(999)
      ) {
        try store.save(envelope)
      }
    }
  }

  /// Rejects envelopes without any safe active Profile candidate.
  @Test
  func rejectsEmptyProfileCollection() throws {
    try withStore { store, _ in
      let envelope = ProfileEnvelope(
        activeProfileID: UUID(),
        profiles: []
      )

      #expect(throws: ProfileValidationError.noProfiles) {
        try store.save(envelope)
      }
    }
  }

  /// Rejects an active identity absent from the Profile collection.
  @Test
  func rejectsMissingActiveProfile() throws {
    try withStore { store, _ in
      let envelope = ProfileEnvelope(
        activeProfileID: UUID(),
        profiles: [Profile.defaultProfile]
      )

      #expect(throws: ProfileValidationError.activeProfileMissing) {
        try store.save(envelope)
      }
    }
  }

  /// Rejects names that collide after normalization.
  @Test
  func rejectsCaseInsensitiveDuplicateNames() throws {
    try withStore { store, _ in
      let first = Profile.defaultProfile
      let duplicate = Profile(
        name: " default ",
        deviceConfigurations: []
      )
      let envelope = ProfileEnvelope(
        activeProfileID: first.id,
        profiles: [first, duplicate]
      )

      #expect(throws: ProfileValidationError.self) {
        try store.save(envelope)
      }
    }
  }

  /// Rejects Profile names that contain only whitespace.
  @Test
  func rejectsEmptyProfileName() throws {
    try withStore { store, _ in
      let profile = Profile(name: "  ", deviceConfigurations: [])
      let envelope = ProfileEnvelope(
        activeProfileID: profile.id,
        profiles: [profile]
      )

      #expect(
        throws: ProfileValidationError.emptyProfileName(profile.id)
      ) {
        try store.save(envelope)
      }
    }
  }

  /// Rejects duplicate persistent Profile identities.
  @Test
  func rejectsDuplicateProfileIDs() throws {
    try withStore { store, _ in
      let first = Profile.defaultProfile
      let duplicate = Profile(
        id: first.id,
        name: "Music",
        deviceConfigurations: []
      )
      let envelope = ProfileEnvelope(
        activeProfileID: first.id,
        profiles: [first, duplicate]
      )

      #expect(throws: ProfileValidationError.self) {
        try store.save(envelope)
      }
    }
  }

  /// Rejects duplicate Device-configuration identities across Profiles.
  @Test
  func rejectsDuplicateDeviceConfigurationIDs() throws {
    try withStore { store, _ in
      let first = Profile.defaultProfile
      let configuration = try #require(
        first.deviceConfigurations.first
      )
      let second = Profile(
        name: "Music",
        deviceConfigurations: [configuration]
      )
      let envelope = ProfileEnvelope(
        activeProfileID: first.id,
        profiles: [first, second]
      )

      #expect(throws: ProfileValidationError.self) {
        try store.save(envelope)
      }
    }
  }

  /// Rejects empty typed model and stable hardware identities.
  @Test
  func rejectsEmptyDeviceIdentities() throws {
    try withStore { store, _ in
      let emptyModelProfile = Profile(
        name: "Empty Model",
        deviceConfigurations: [
          ProfileDeviceConfiguration(
            matchRule: DeviceMatchRule(
              modelID: DeviceModelID(rawValue: " ")
            ),
            bindings: []
          )
        ]
      )
      let emptyModelEnvelope = ProfileEnvelope(
        activeProfileID: emptyModelProfile.id,
        profiles: [emptyModelProfile]
      )
      #expect(throws: ProfileValidationError.self) {
        try store.save(emptyModelEnvelope)
      }

      let emptyStableProfile = Profile(
        name: "Empty Stable ID",
        deviceConfigurations: [
          ProfileDeviceConfiguration(
            matchRule: DeviceMatchRule(
              modelID: .vecInfinity3,
              stableHardwareID: " "
            ),
            bindings: []
          )
        ]
      )
      let emptyStableEnvelope = ProfileEnvelope(
        activeProfileID: emptyStableProfile.id,
        profiles: [emptyStableProfile]
      )
      #expect(throws: ProfileValidationError.self) {
        try store.save(emptyStableEnvelope)
      }
    }
  }

  /// Rejects duplicate match rules inside one Profile.
  @Test
  func rejectsDuplicateDeviceMatches() throws {
    try withStore { store, _ in
      var profile = Profile.defaultProfile
      profile.deviceConfigurations.append(
        ProfileDeviceConfiguration(
          matchRule: infinity,
          bindings: []
        )
      )
      let envelope = ProfileEnvelope(
        activeProfileID: profile.id,
        profiles: [profile]
      )

      #expect(throws: ProfileValidationError.self) {
        try store.save(envelope)
      }
    }
  }

  @Test
  func rejectsDuplicateBindings() throws {
    try withStore { store, _ in
      var profile = Profile.defaultProfile
      profile.deviceConfigurations[0].bindings.append(
        Binding(
          controlID: .center,
          interactionMode: .toggle,
          action: .dictation()
        )
      )
      let envelope = ProfileEnvelope(
        activeProfileID: profile.id,
        profiles: [profile]
      )

      #expect(throws: ProfileValidationError.self) {
        try store.save(envelope)
      }
    }
  }

  @Test(
    arguments: [
      ActionConfiguration(
        kind: .noAction,
        shortcut: KeyboardShortcut(keyCode: 1)
      ),
      ActionConfiguration(
        kind: .dictation,
        shortcut: KeyboardShortcut(keyCode: 1)
      ),
      ActionConfiguration(
        kind: .localAIDictation,
        shortcut: KeyboardShortcut(keyCode: 1)
      ),
      ActionConfiguration(kind: .keyboardShortcut),
    ]
  )
  func rejectsInvalidActionConfiguration(
    _ action: ActionConfiguration
  ) throws {
    try withStore { store, _ in
      var profile = Profile.defaultProfile
      let configuration = try #require(
        profile.configuration(matching: infinity)
      )
      var center = try #require(
        configuration.binding(for: .center)
      )
      center.action = action
      try profile.setBinding(
        center,
        configurationID: configuration.id
      )
      let envelope = ProfileEnvelope(
        activeProfileID: profile.id,
        profiles: [profile]
      )

      #expect(throws: ProfileValidationError.self) {
        try store.save(envelope)
      }
    }
  }

  /// Rejects one fallback that has no executable Action target.
  @Test
  func rejectsFallbackWithoutAction() throws {
    try withStore { store, _ in
      var profile = Profile.defaultProfile
      let configuration = try #require(profile.deviceConfigurations.first)
      var left = try #require(configuration.binding(for: .left))
      left.activationShortcut = .suggestedControlActivation
      try profile.setBinding(left, configurationID: configuration.id)
      let envelope = ProfileEnvelope(
        activeProfileID: profile.id,
        profiles: [profile]
      )

      #expect(throws: ProfileValidationError.self) {
        try store.save(envelope)
      }
    }
  }

  /// Rejects ambiguous fallback routing inside one active Profile.
  @Test
  func rejectsDuplicateFallbackShortcuts() throws {
    try withStore { store, _ in
      var profile = Profile.defaultProfile
      let configuration = try #require(profile.deviceConfigurations.first)
      var center = try #require(configuration.binding(for: .center))
      var right = try #require(configuration.binding(for: .right))
      center.activationShortcut = .suggestedControlActivation
      right.action = .dictation()
      right.activationShortcut = .suggestedControlActivation
      try profile.setBinding(center, configurationID: configuration.id)
      try profile.setBinding(right, configurationID: configuration.id)
      let envelope = ProfileEnvelope(
        activeProfileID: profile.id,
        profiles: [profile]
      )

      #expect(throws: ProfileValidationError.self) {
        try store.save(envelope)
      }
    }
  }

  /// Prevents a global fallback from capturing ordinary or lightly modified input.
  @Test
  func rejectsFallbackWithFewerThanTwoModifiers() throws {
    try withStore { store, _ in
      var profile = Profile.defaultProfile
      let configuration = try #require(profile.deviceConfigurations.first)
      var center = try #require(configuration.binding(for: .center))
      center.activationShortcut = KeyboardShortcut(
        keyCode: 2,
        modifiers: [.command]
      )
      try profile.setBinding(center, configurationID: configuration.id)
      let envelope = ProfileEnvelope(
        activeProfileID: profile.id,
        profiles: [profile]
      )

      #expect(throws: ProfileValidationError.self) {
        try store.save(envelope)
      }
    }
  }

  /// Prevents a fallback from recursively posting its own output shortcut.
  @Test
  func rejectsFallbackThatMatchesAnOutputShortcut() throws {
    try withStore { store, _ in
      var profile = Profile.defaultProfile
      let configuration = try #require(profile.deviceConfigurations.first)
      var left = try #require(configuration.binding(for: .left))
      var center = try #require(configuration.binding(for: .center))
      left.action = .keyboardShortcut(.suggestedControlActivation)
      center.activationShortcut = .suggestedControlActivation
      try profile.setBinding(left, configurationID: configuration.id)
      try profile.setBinding(center, configurationID: configuration.id)
      let envelope = ProfileEnvelope(
        activeProfileID: profile.id,
        profiles: [profile]
      )

      #expect(throws: ProfileValidationError.self) {
        try store.save(envelope)
      }
    }
  }

  /// Encodes one historical global-Binding envelope.
  private func legacyData(
    schemaVersion: Int,
    profileID: UUID,
    bindings: [Binding]
  ) throws -> Data {
    try JSONEncoder().encode(
      LegacyProfileEnvelope(
        schemaVersion: schemaVersion,
        activeProfileID: profileID,
        profiles: [
          LegacyProfile(
            id: profileID,
            name: "Default",
            bindings: bindings
          )
        ]
      )
    )
  }

  /// Creates and removes one isolated Profile store.
  private func withStore(
    _ operation: (ProfileStore, URL) throws -> Void
  ) throws {
    let directory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath
    )
    .appendingPathComponent(".build", isDirectory: true)
    .appendingPathComponent("profile_store_tests", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    try operation(
      ProfileStore(
        fileURL: directory.appendingPathComponent("profiles.json")
      ),
      directory
    )
  }
}

private struct LegacyProfileEnvelope: Encodable {
  let schemaVersion: Int
  let activeProfileID: UUID
  let profiles: [LegacyProfile]
}

private struct LegacyProfile: Encodable {
  let id: UUID
  let name: String
  let bindings: [Binding]
}

private enum StubProfileStoreFailure: Error {
  case read
  case write
  case copy
}

private struct StubProfileStoreFileAccess:
  ProfileStoreFileAccessing
{
  let readResult: Result<Data, StubProfileStoreFailure>
  var writeError: StubProfileStoreFailure?
  var copyError: StubProfileStoreFailure?

  /// Reports one deterministic file as present.
  func fileExists(at url: URL) -> Bool {
    true
  }

  /// Returns or throws the configured read result.
  func read(from url: URL) throws -> Data {
    try readResult.get()
  }

  /// Accepts deterministic directory creation.
  func createDirectory(at url: URL) throws {}

  /// Throws only when the test configures a write failure.
  func write(_ data: Data, to url: URL) throws {
    if let writeError {
      throw writeError
    }
  }

  /// Throws only when the test configures a backup failure.
  func copyItem(at source: URL, to destination: URL) throws {
    if let copyError {
      throw copyError
    }
  }
}
