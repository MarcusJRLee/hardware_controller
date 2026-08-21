import Foundation
import HardwareControllerCore
import HardwareControllerMac
import Testing

@testable import HardwareControllerApp

struct ApplicationPreferencesStoreTests {
  private let fileURL = URL(fileURLWithPath: "/preferences.json")

  /// Loads conservative defaults without writing a missing file.
  @Test
  func missingFileLoadsDefaultsWithoutWriting() {
    let files = PreferenceFileAccess()
    let result = makeStore(files: files).load()

    #expect(result.preferences == .default)
    #expect(result.issue == nil)
    #expect(files.writes.isEmpty)
  }

  /// Writes and decodes one complete versioned preference value.
  @Test
  func roundTripsPreferences() throws {
    let files = PreferenceFileAccess()
    let store = makeStore(files: files)
    let preferences = ApplicationPreferences(
      appearance: .dark,
      sidebarVisibility: .collapsed,
      preferredMicrophone: PreferredMicrophone(
        device: AudioInputDevice(
          uniqueID: "usb-microphone",
          name: "USB Microphone"
        )
      ),
      localAI: LocalAISettings(
        provider: .ollama,
        ollamaModel: LocalAIModelSelection(
          name: "qwen3.5:4b",
          expectedDigest: "sha256:expected"
        ),
        includeNearbyText: true
      )
    )

    try store.save(preferences)
    guard let data = files.writes.last else {
      Issue.record("Expected one preference write.")
      return
    }
    files.data = data
    let result = store.load()

    #expect(result.preferences == preferences)
    #expect(result.issue == nil)
    #expect(files.createdDirectories == [fileURL.deletingLastPathComponent()])
  }

  /// Migrates schema 2 preferences with conservative Local AI defaults.
  @Test
  func schemaTwoLoadsWithDefaultLocalAISettings() {
    let files = PreferenceFileAccess()
    files.data = Data(
      """
      {
        "appearance": "system",
        "schemaVersion": 2,
        "sidebarVisibility": "expanded"
      }
      """.utf8
    )

    let result = makeStore(files: files).load()

    #expect(result.issue == nil)
    #expect(result.preferences.localAI == .default)
    #expect(
      result.preferences.schemaVersion
        == ApplicationPreferences.currentSchemaVersion
    )
  }

  /// Migrates schema 1 presentation preferences to system-default input.
  @Test
  func schemaOneLoadsWithSystemDefaultMicrophone() {
    let files = PreferenceFileAccess()
    files.data = Data(
      """
      {
        "appearance": "dark",
        "schemaVersion": 1,
        "sidebarVisibility": "collapsed"
      }
      """.utf8
    )

    let result = makeStore(files: files).load()

    #expect(result.issue == nil)
    #expect(result.preferences.appearance == .dark)
    #expect(result.preferences.sidebarVisibility == .collapsed)
    #expect(result.preferences.preferredMicrophone == nil)
    #expect(
      result.preferences.schemaVersion
        == ApplicationPreferences.currentSchemaVersion
    )
  }

  /// Preserves a semantically invalid microphone preference for recovery.
  @Test
  func emptyMicrophoneIdentityIsRejected() throws {
    let files = PreferenceFileAccess()
    files.data = Data(
      """
      {
        "appearance": "system",
        "preferredMicrophone": { "id": "", "name": "USB Microphone" },
        "schemaVersion": 2,
        "sidebarVisibility": "expanded"
      }
      """.utf8
    )

    let result = makeStore(files: files).load()

    #expect(result.preferences == .default)
    guard case .recoveredInvalidFile = try #require(result.issue) else {
      Issue.record("Expected invalid microphone recovery.")
      return
    }
    #expect(files.copies.count == 1)
  }

  /// Preserves invalid input and returns conservative defaults.
  @Test
  func invalidFileIsCopiedBeforeRecovery() throws {
    let files = PreferenceFileAccess()
    files.data = Data("not-json".utf8)
    let result = makeStore(files: files).load()

    #expect(result.preferences == .default)
    let issue = try #require(result.issue)
    guard case .recoveredInvalidFile(let backupURL, nil) = issue else {
      Issue.record("Expected invalid-file recovery.")
      return
    }
    #expect(
      backupURL?.lastPathComponent.hasPrefix(
        "preferences.corrupt-"
      ) == true)
    #expect(files.copies.count == 1)
    #expect(files.data == Data("not-json".utf8))
  }

  /// Leaves future-schema preferences untouched for a newer app.
  @Test
  func futureSchemaIsNotClassifiedAsCorruptOrOverwritten() throws {
    let files = PreferenceFileAccess()
    files.data = Data(
      """
      {
        "appearance": "system",
        "schemaVersion": 99,
        "sidebarVisibility": "expanded"
      }
      """.utf8
    )
    let store = makeStore(files: files)

    let result = store.load()

    #expect(result.preferences == .default)
    #expect(result.issue == .requiresNewerApp(schemaVersion: 99))
    #expect(files.copies.isEmpty)
    #expect(
      throws:
        ApplicationPreferencesValidationError
        .unsupportedSchemaVersion(99)
    ) {
      try store.save(.default)
    }
    #expect(files.writes.isEmpty)
  }

  /// Reports read failures without classifying the file as corrupt.
  @Test
  func readFailureIsReportedDirectly() throws {
    let files = PreferenceFileAccess()
    files.data = Data()
    files.readFails = true
    let result = makeStore(files: files).load()

    guard case .couldNotReadFile = try #require(result.issue) else {
      Issue.record("Expected a read failure.")
      return
    }
    #expect(files.copies.isEmpty)
  }

  /// Keeps backup failures visible during invalid-file recovery.
  @Test
  func backupFailureIsReported() throws {
    let files = PreferenceFileAccess()
    files.data = Data("invalid".utf8)
    files.copyFails = true
    let result = makeStore(files: files).load()

    guard
      case .recoveredInvalidFile(nil, let message) = try #require(
        result.issue
      )
    else {
      Issue.record("Expected a backup failure.")
      return
    }
    #expect(message != nil)
  }

  /// Propagates atomic write failures without recording a write.
  @Test
  func writeFailureIsExplicit() {
    let files = PreferenceFileAccess()
    files.writeFails = true

    #expect(throws: PreferenceTestError.writeFailed) {
      try makeStore(files: files).save(.default)
    }
    #expect(files.writes.isEmpty)
  }

  /// Creates one deterministic store around the supplied file seam.
  private func makeStore(
    files: PreferenceFileAccess
  ) -> ApplicationPreferencesStore {
    ApplicationPreferencesStore(
      fileURL: fileURL,
      fileAccess: files
    )
  }
}

@MainActor
struct ApplicationPreferencesModelTests {
  /// Applies a saved candidate only after persistence succeeds.
  @Test
  func appearanceChangeIsTransactional() {
    let store = PreferenceStore()
    let applier = AppearanceApplier()
    let model = ApplicationPreferencesModel(
      arguments: [],
      isDemoMode: false,
      appearanceApplier: applier,
      store: store
    )

    model.setAppearance(.dark)

    #expect(model.appearance == .dark)
    #expect(store.saved.map(\.appearance) == [.dark])
    #expect(applier.applied == [.system, .dark])
  }

  /// Keeps the effective appearance unchanged after a failed save.
  @Test
  func failedAppearanceSaveDoesNotApplyCandidate() {
    let store = PreferenceStore(saveFails: true)
    let applier = AppearanceApplier()
    let model = ApplicationPreferencesModel(
      arguments: [],
      isDemoMode: false,
      appearanceApplier: applier,
      store: store
    )

    model.setAppearance(.dark)

    #expect(model.appearance == .system)
    #expect(model.lastError != nil)
    #expect(applier.applied == [.system])
  }

  /// Reports a failed sidebar save and preserves effective visibility.
  @Test
  func failedSidebarSaveRejectsCandidate() {
    let store = PreferenceStore(saveFails: true)
    let model = ApplicationPreferencesModel(
      arguments: [],
      isDemoMode: false,
      appearanceApplier: AppearanceApplier(),
      store: store
    )

    let saved = model.setSidebarVisibility(.collapsed)

    #expect(!saved)
    #expect(model.sidebarVisibility == .expanded)
  }

  /// Ignores persisted appearance when a deterministic demo override exists.
  @Test
  func demoOverrideWinsWithoutWriting() {
    let store = PreferenceStore(
      preferences: ApplicationPreferences(appearance: .dark)
    )
    let applier = AppearanceApplier()
    let model = ApplicationPreferencesModel(
      arguments: ["--ui-light"],
      isDemoMode: true,
      appearanceApplier: applier,
      store: store
    )

    #expect(model.appearance == .light)
    #expect(store.saved.isEmpty)
    #expect(applier.applied == [.light])
  }

  /// Persists before applying one explicit microphone selection.
  @Test
  func microphoneSelectionIsTransactional() {
    let store = PreferenceStore()
    let discovery = MicrophoneDiscovery(
      devices: [
        AudioInputDevice(
          uniqueID: "usb-microphone",
          name: "USB Microphone"
        )
      ]
    )
    let model = ApplicationPreferencesModel(
      arguments: [],
      isDemoMode: false,
      appearanceApplier: AppearanceApplier(),
      store: store,
      microphoneDiscovery: discovery
    )
    var applied: [String?] = []
    model.setMicrophoneSelectionHandler {
      applied.append($0)
    }

    let saved = model.setPreferredMicrophone(
      uniqueID: "usb-microphone"
    )

    #expect(saved)
    #expect(model.preferredMicrophone?.name == "USB Microphone")
    #expect(
      store.saved.map(\.preferredMicrophone)
        == [model.preferredMicrophone]
    )
    #expect(applied == ["usb-microphone"])
  }

  /// Persists Local AI settings before applying them to process services.
  @Test
  func localAISettingsChangeIsTransactional() {
    let store = PreferenceStore()
    let model = ApplicationPreferencesModel(
      arguments: [],
      isDemoMode: false,
      appearanceApplier: AppearanceApplier(),
      store: store
    )
    var applied: [LocalAISettings] = []
    model.setLocalAISettingsHandler { applied.append($0) }
    let settings = LocalAISettings(
      provider: .ollama,
      ollamaModel: LocalAIModelSelection(
        name: "qwen3.5:9b",
        expectedDigest: "sha256:model"
      )
    )

    #expect(model.setLocalAISettings(settings))

    #expect(model.localAISettings == settings)
    #expect(store.saved.map(\.localAI) == [settings])
    #expect(applied == [settings])
  }

  /// Retains a disconnected preference while reporting default fallback.
  @Test
  func unavailableMicrophoneRemainsVisible() {
    let preferred = PreferredMicrophone(
      device: AudioInputDevice(
        uniqueID: "wireless-microphone",
        name: "Wireless Microphone"
      )
    )
    let model = ApplicationPreferencesModel(
      arguments: [],
      isDemoMode: false,
      appearanceApplier: AppearanceApplier(),
      store: PreferenceStore(
        preferences: ApplicationPreferences(
          preferredMicrophone: preferred
        )
      ),
      microphoneDiscovery: MicrophoneDiscovery(devices: [])
    )

    #expect(!model.isPreferredMicrophoneAvailable)
    #expect(model.microphoneOptions == [preferred])
    #expect(
      model.microphoneStatusDetail
        == "Wireless Microphone is unavailable. System Default is active until it reconnects."
    )
    #expect(
      model.microphoneTitle(preferred)
        == "Wireless Microphone — Unavailable"
    )
  }

  /// Presents a typed discovery failure instead of an empty picker silently.
  @Test
  func microphoneDiscoveryFailureIsActionable() {
    let model = ApplicationPreferencesModel(
      arguments: [],
      isDemoMode: false,
      appearanceApplier: AppearanceApplier(),
      store: PreferenceStore(),
      microphoneDiscovery: MicrophoneDiscovery(
        error: .unavailable
      )
    )

    #expect(
      model.microphoneStatusDetail
        == "Microphones could not be listed: Test microphones are unavailable."
    )
  }
}

/// Returns deterministic microphone choices to the preference model.
private struct MicrophoneDiscovery: AudioInputDeviceDiscovering {
  let devices: [AudioInputDevice]
  let error: MicrophoneDiscoveryTestError?

  /// Creates a deterministic success or failure.
  init(
    devices: [AudioInputDevice] = [],
    error: MicrophoneDiscoveryTestError? = nil
  ) {
    self.devices = devices
    self.error = error
  }

  /// Returns the injected Device list.
  func availableInputDevices() throws -> [AudioInputDevice] {
    if let error {
      throw error
    }
    return devices
  }
}

/// Produces one stable localized discovery failure.
private enum MicrophoneDiscoveryTestError: LocalizedError {
  case unavailable

  var errorDescription: String? {
    "Test microphones are unavailable."
  }
}

/// Provides lock-protected deterministic preference file access.
private final class PreferenceFileAccess:
  ApplicationPreferencesFileAccessing,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storage: Data?
  private var writeStorage: [Data] = []
  private var directoryStorage: [URL] = []
  private var copyStorage: [(URL, URL)] = []
  private var failsRead = false
  private var failsWrite = false
  private var failsCopy = false

  var data: Data? {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }

  var readFails: Bool {
    get { lock.withLock { failsRead } }
    set { lock.withLock { failsRead = newValue } }
  }

  var writeFails: Bool {
    get { lock.withLock { failsWrite } }
    set { lock.withLock { failsWrite = newValue } }
  }

  var copyFails: Bool {
    get { lock.withLock { failsCopy } }
    set { lock.withLock { failsCopy = newValue } }
  }

  var writes: [Data] {
    lock.withLock { writeStorage }
  }

  var createdDirectories: [URL] {
    lock.withLock { directoryStorage }
  }

  var copies: [(URL, URL)] {
    lock.withLock { copyStorage }
  }

  /// Reports whether deterministic file data exists.
  func fileExists(at url: URL) -> Bool {
    lock.withLock { storage != nil }
  }

  /// Returns deterministic data or a configured read failure.
  func read(from url: URL) throws -> Data {
    try lock.withLock {
      if failsRead {
        throw PreferenceTestError.readFailed
      }
      return storage ?? Data()
    }
  }

  /// Records one requested parent directory.
  func createDirectory(at url: URL) throws {
    lock.withLock { directoryStorage.append(url) }
  }

  /// Records one complete atomic write payload.
  func write(_ data: Data, to url: URL) throws {
    try lock.withLock {
      if failsWrite {
        throw PreferenceTestError.writeFailed
      }
      writeStorage.append(data)
    }
  }

  /// Records one recovery copy without mutating the source.
  func copyItem(at source: URL, to destination: URL) throws {
    try lock.withLock {
      if failsCopy {
        throw PreferenceTestError.writeFailed
      }
      copyStorage.append((source, destination))
    }
  }
}

/// Stores deterministic model transactions.
private final class PreferenceStore:
  ApplicationPreferencesPersisting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let preferences: ApplicationPreferences
  private let saveFails: Bool
  private var savedStorage: [ApplicationPreferences] = []

  /// Creates one deterministic preference store.
  init(
    preferences: ApplicationPreferences = .default,
    saveFails: Bool = false
  ) {
    self.preferences = preferences
    self.saveFails = saveFails
  }

  var saved: [ApplicationPreferences] {
    lock.withLock { savedStorage }
  }

  /// Returns one deterministic preference value.
  func load() -> ApplicationPreferencesLoadResult {
    ApplicationPreferencesLoadResult(
      preferences: preferences,
      issue: nil
    )
  }

  /// Records a candidate or throws the configured failure.
  func save(_ preferences: ApplicationPreferences) throws {
    try lock.withLock {
      if saveFails {
        throw PreferenceTestError.writeFailed
      }
      savedStorage.append(preferences)
    }
  }
}

/// Records application-wide appearance changes.
@MainActor
private final class AppearanceApplier: ApplicationAppearanceApplying {
  private(set) var applied: [ApplicationAppearance] = []

  /// Records one effective application appearance.
  func apply(_ appearance: ApplicationAppearance) {
    applied.append(appearance)
  }
}

/// Identifies deterministic preference seam failures.
private enum PreferenceTestError: Error {
  case readFailed
  case writeFailed
}
