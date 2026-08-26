import Foundation
import HardwareControllerCore
import HardwareControllerMac
import Observation

/// Selects the app-wide macOS appearance policy.
enum ApplicationAppearance: String, Codable, CaseIterable, Sendable {
  case system
  case light
  case dark

  /// Returns the user-facing native preference label.
  var title: String {
    switch self {
    case .system:
      "System"
    case .light:
      "Light"
    case .dark:
      "Dark"
    }
  }
}

/// Stores only the user's durable sidebar visibility choice.
enum SidebarVisibilityPreference: String, Codable, Sendable {
  case expanded
  case collapsed
}

/// Persists one stable microphone preference without CoreAudio object IDs.
struct PreferredMicrophone: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let name: String

  /// Copies the stable identity and current user-facing name.
  init(device: AudioInputDevice) {
    id = device.uniqueID
    name = device.name
  }
}

/// Stores versioned application presentation preferences.
struct ApplicationPreferences: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 6

  var appearance: ApplicationAppearance
  var sidebarVisibility: SidebarVisibilityPreference
  var preferredMicrophone: PreferredMicrophone?
  var localAI: LocalAISettings
  var voiceTrigger: VoiceTriggerSettings
  var voiceHistoryRetention: VoiceHistoryRetentionSettings
  var schemaVersion: Int

  /// Creates one complete preference value.
  init(
    appearance: ApplicationAppearance = .system,
    sidebarVisibility: SidebarVisibilityPreference = .expanded,
    preferredMicrophone: PreferredMicrophone? = nil,
    localAI: LocalAISettings = .default,
    voiceTrigger: VoiceTriggerSettings = .default,
    voiceHistoryRetention: VoiceHistoryRetentionSettings = .macOSDefault,
    schemaVersion: Int = currentSchemaVersion
  ) {
    self.appearance = appearance
    self.sidebarVisibility = sidebarVisibility
    self.preferredMicrophone = preferredMicrophone
    self.localAI = localAI
    self.voiceTrigger = voiceTrigger
    self.voiceHistoryRetention = voiceHistoryRetention
    self.schemaVersion = schemaVersion
  }

  private enum CodingKeys: String, CodingKey {
    case appearance
    case sidebarVisibility
    case preferredMicrophone
    case localAI
    case voiceTrigger
    case voiceHistoryRetention
    case schemaVersion
  }

  /// Decodes older schemas before migration supplies Local AI defaults.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    appearance = try container.decode(
      ApplicationAppearance.self,
      forKey: .appearance
    )
    sidebarVisibility = try container.decode(
      SidebarVisibilityPreference.self,
      forKey: .sidebarVisibility
    )
    preferredMicrophone = try container.decodeIfPresent(
      PreferredMicrophone.self,
      forKey: .preferredMicrophone
    )
    localAI =
      try container.decodeIfPresent(
        LocalAISettings.self,
        forKey: .localAI
      ) ?? .default
    voiceTrigger =
      try container.decodeIfPresent(
        VoiceTriggerSettings.self,
        forKey: .voiceTrigger
      ) ?? .default
    voiceHistoryRetention =
      try container.decodeIfPresent(
        VoiceHistoryRetentionSettings.self,
        forKey: .voiceHistoryRetention
      ) ?? .macOSDefault
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
  }

  static let `default` = ApplicationPreferences()
}

/// Describes a recoverable preference-load problem.
enum ApplicationPreferencesStoreIssue: Equatable, Sendable {
  case couldNotReadFile(message: String)
  case requiresNewerApp(schemaVersion: Int)
  case recoveredInvalidFile(
    backupURL: URL?,
    backupFailureMessage: String?
  )
}

/// Returns preferences with any recoverable load issue.
struct ApplicationPreferencesLoadResult: Sendable {
  let preferences: ApplicationPreferences
  let issue: ApplicationPreferencesStoreIssue?
}

/// Identifies unsupported preference data explicitly.
enum ApplicationPreferencesValidationError: Error, Equatable, Sendable {
  case unsupportedSchemaVersion(Int)
  case invalidPreferredMicrophone
  case invalidLocalAISettings(LocalAISettingsValidationError)
  case invalidVoiceTriggerSettings(VoiceTriggerSettingsValidationError)
  case invalidVoiceHistoryRetention(VoiceHistoryRetentionValidationError)
}

/// Isolates preference persistence from presentation state.
protocol ApplicationPreferencesPersisting: Sendable {
  /// Loads current preferences and any recoverable issue.
  func load() -> ApplicationPreferencesLoadResult

  /// Persists one validated preference value atomically.
  func save(_ preferences: ApplicationPreferences) throws
}

/// Persists versioned application preferences as atomic local JSON.
struct ApplicationPreferencesStore:
  ApplicationPreferencesPersisting,
  Sendable
{
  let fileURL: URL
  private let fileAccess: any ApplicationPreferencesFileAccessing

  /// Creates a store backed by local file-system access.
  init(fileURL: URL) {
    self.fileURL = fileURL
    fileAccess = LocalApplicationPreferencesFileAccess()
  }

  /// Creates a store around deterministic file access for tests.
  init(
    fileURL: URL,
    fileAccess: any ApplicationPreferencesFileAccessing
  ) {
    self.fileURL = fileURL
    self.fileAccess = fileAccess
  }

  /// Resolves the app's Application Support preference file.
  static func applicationSupportStore(
    fileManager: FileManager = .default
  ) throws -> ApplicationPreferencesStore {
    let applicationSupport =
      try ApplicationIdentity.applicationSupportDirectory(
        fileManager: fileManager
      )
    return ApplicationPreferencesStore(
      fileURL:
        applicationSupport
        .appendingPathComponent("preferences.json")
    )
  }

  /// Loads validated preferences or a conservative recoverable default.
  func load() -> ApplicationPreferencesLoadResult {
    guard fileAccess.fileExists(at: fileURL) else {
      return ApplicationPreferencesLoadResult(
        preferences: .default,
        issue: nil
      )
    }

    let data: Data
    do {
      data = try fileAccess.read(from: fileURL)
    } catch {
      return ApplicationPreferencesLoadResult(
        preferences: .default,
        issue: .couldNotReadFile(
          message: error.localizedDescription
        )
      )
    }

    do {
      let schemaVersion = try JSONDecoder().decode(
        ApplicationPreferencesSchemaProbe.self,
        from: data
      ).schemaVersion
      if schemaVersion > ApplicationPreferences.currentSchemaVersion {
        return ApplicationPreferencesLoadResult(
          preferences: .default,
          issue: .requiresNewerApp(schemaVersion: schemaVersion)
        )
      }
      let decoded = try JSONDecoder().decode(
        ApplicationPreferences.self,
        from: data
      )
      let preferences = try migrate(decoded)
      try validate(preferences)
      return ApplicationPreferencesLoadResult(
        preferences: preferences,
        issue: nil
      )
    } catch {
      return recoverInvalidFile()
    }
  }

  /// Validates and atomically saves one complete preference value.
  func save(_ preferences: ApplicationPreferences) throws {
    try validate(preferences)
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
    try fileAccess.write(
      encoder.encode(preferences),
      to: fileURL
    )
  }

  /// Rejects preference schemas this app cannot interpret safely.
  func validate(_ preferences: ApplicationPreferences) throws {
    guard
      preferences.schemaVersion
        == ApplicationPreferences.currentSchemaVersion
    else {
      throw
        ApplicationPreferencesValidationError
        .unsupportedSchemaVersion(preferences.schemaVersion)
    }
    if let microphone = preferences.preferredMicrophone {
      guard
        !microphone.id.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty,
        !microphone.name.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty
      else {
        throw ApplicationPreferencesValidationError
          .invalidPreferredMicrophone
      }
    }
    do {
      try preferences.localAI.validate()
    } catch let error as LocalAISettingsValidationError {
      throw
        ApplicationPreferencesValidationError
        .invalidLocalAISettings(error)
    }
    do {
      try preferences.voiceTrigger.validate()
    } catch let error as VoiceTriggerSettingsValidationError {
      throw
        ApplicationPreferencesValidationError
        .invalidVoiceTriggerSettings(error)
    }
    do {
      _ = try preferences.voiceHistoryRetention.validated()
    } catch let error as VoiceHistoryRetentionValidationError {
      throw
        ApplicationPreferencesValidationError
        .invalidVoiceHistoryRetention(error)
    }
  }

  /// Migrates every supported preference schema without changing user intent.
  private func migrate(
    _ preferences: ApplicationPreferences
  ) throws -> ApplicationPreferences {
    switch preferences.schemaVersion {
    case 1, 2, 3, 4, 5:
      var migrated = preferences
      migrated.schemaVersion = ApplicationPreferences.currentSchemaVersion
      if preferences.schemaVersion == 1 {
        migrated.preferredMicrophone = nil
      }
      if preferences.schemaVersion < 3 {
        migrated.localAI = .default
      }
      if preferences.schemaVersion < 4 {
        migrated.voiceTrigger = .default
      }
      if preferences.schemaVersion < 6 {
        migrated.voiceHistoryRetention = .macOSDefault
      }
      return migrated
    case ApplicationPreferences.currentSchemaVersion:
      return preferences
    default:
      throw
        ApplicationPreferencesValidationError
        .unsupportedSchemaVersion(preferences.schemaVersion)
    }
  }

  /// Prevents an older app from overwriting preferences it cannot interpret.
  private func rejectNewerStoredSchema() throws {
    guard fileAccess.fileExists(at: fileURL) else {
      return
    }
    let data = try fileAccess.read(from: fileURL)
    guard
      let schemaVersion = try? JSONDecoder().decode(
        ApplicationPreferencesSchemaProbe.self,
        from: data
      ).schemaVersion,
      schemaVersion > ApplicationPreferences.currentSchemaVersion
    else {
      return
    }
    throw
      ApplicationPreferencesValidationError
      .unsupportedSchemaVersion(schemaVersion)
  }

  /// Preserves invalid input and returns conservative defaults.
  private func recoverInvalidFile() -> ApplicationPreferencesLoadResult {
    let backup = preserveInvalidFile()
    return ApplicationPreferencesLoadResult(
      preferences: .default,
      issue: .recoveredInvalidFile(
        backupURL: backup.url,
        backupFailureMessage: backup.failureMessage
      )
    )
  }

  /// Copies invalid input without mutating the original file.
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
      try fileAccess.copyItem(at: fileURL, to: backupURL)
      return (backupURL, nil)
    } catch {
      return (nil, error.localizedDescription)
    }
  }
}

private struct ApplicationPreferencesSchemaProbe: Decodable {
  let schemaVersion: Int
}

/// Supplies deterministic no-write preferences for demos and previews.
private struct PreviewApplicationPreferencesStore:
  ApplicationPreferencesPersisting
{
  /// Returns conservative defaults without touching user data.
  func load() -> ApplicationPreferencesLoadResult {
    ApplicationPreferencesLoadResult(
      preferences: .default,
      issue: nil
    )
  }

  /// Accepts demo-only changes without writing user data.
  func save(_ preferences: ApplicationPreferences) throws {}
}

/// Supplies stable microphone choices for demos and previews.
private struct PreviewAudioInputDeviceDiscovery:
  AudioInputDeviceDiscovering
{
  /// Returns deterministic choices without inspecting real hardware.
  func availableInputDevices() throws -> [AudioInputDevice] {
    [
      AudioInputDevice(
        uniqueID: "demo-built-in-microphone",
        name: "Mac Microphone"
      ),
      AudioInputDevice(
        uniqueID: "demo-usb-microphone",
        name: "USB Microphone"
      ),
    ]
  }
}

/// Applies a persisted appearance to the complete macOS application.
@MainActor
protocol ApplicationAppearanceApplying: AnyObject {
  /// Applies one typed appearance choice.
  func apply(_ appearance: ApplicationAppearance)
}

/// Owns transactional presentation preferences on the main actor.
@MainActor
@Observable
final class ApplicationPreferencesModel {
  private(set) var preferences: ApplicationPreferences
  private(set) var availableMicrophones: [AudioInputDevice] = []
  private(set) var microphoneDiscoveryError: String?
  private(set) var lastError: String?
  private(set) var recoveryNotice: String?

  @ObservationIgnored
  private let store: any ApplicationPreferencesPersisting
  @ObservationIgnored
  private let microphoneDiscovery: any AudioInputDeviceDiscovering
  @ObservationIgnored
  private weak var appearanceApplier: (any ApplicationAppearanceApplying)?
  @ObservationIgnored
  private var microphoneSelectionHandler: ((String?) -> Void)?
  @ObservationIgnored
  private var localAISettingsHandler: ((LocalAISettings) -> Void)?
  @ObservationIgnored
  private var voiceTriggerSettingsHandler: ((VoiceTriggerSettings) -> Void)?
  @ObservationIgnored
  private var voiceHistoryRetentionHandler: ((VoiceHistoryRetentionSettings) -> Void)?

  /// Loads, overrides, and applies presentation preferences once.
  init(
    arguments: [String],
    isDemoMode: Bool,
    appearanceApplier: any ApplicationAppearanceApplying,
    store providedStore: (any ApplicationPreferencesPersisting)? = nil,
    microphoneDiscovery providedMicrophoneDiscovery:
      (any AudioInputDeviceDiscovering)? = nil
  ) {
    let store =
      providedStore
      ?? (isDemoMode
        ? PreviewApplicationPreferencesStore()
        : Self.makeStore())
    let result = store.load()
    var preferences = result.preferences
    if isDemoMode,
      let override = ApplicationAppearance.demoOverride(
        arguments: arguments
      )
    {
      preferences.appearance = override
    }

    self.store = store
    microphoneDiscovery =
      providedMicrophoneDiscovery
      ?? (isDemoMode
        ? PreviewAudioInputDeviceDiscovery()
        : SystemAudioInputDeviceDiscovery())
    self.preferences = preferences
    self.appearanceApplier = appearanceApplier
    recoveryNotice = Self.notice(for: result.issue)
    appearanceApplier.apply(preferences.appearance)
    refreshMicrophones()
  }

  var appearance: ApplicationAppearance {
    preferences.appearance
  }

  var sidebarVisibility: SidebarVisibilityPreference {
    preferences.sidebarVisibility
  }

  var preferredMicrophone: PreferredMicrophone? {
    preferences.preferredMicrophone
  }

  var localAISettings: LocalAISettings {
    preferences.localAI
  }

  var voiceTriggerSettings: VoiceTriggerSettings {
    preferences.voiceTrigger
  }

  var voiceHistoryRetention: VoiceHistoryRetentionSettings {
    preferences.voiceHistoryRetention
  }

  /// Keeps an unavailable saved Device selectable while default fallback is active.
  var microphoneOptions: [PreferredMicrophone] {
    var options = availableMicrophones.map(PreferredMicrophone.init)
    if let preferredMicrophone,
      !options.contains(where: { $0.id == preferredMicrophone.id })
    {
      options.append(preferredMicrophone)
    }
    return options
  }

  var isPreferredMicrophoneAvailable: Bool {
    guard let preferredMicrophone else {
      return true
    }
    return availableMicrophones.contains {
      $0.uniqueID == preferredMicrophone.id
    }
  }

  var microphoneStatusDetail: String {
    if let microphoneDiscoveryError {
      return microphoneDiscoveryError
    }
    if !isPreferredMicrophoneAvailable,
      let preferredMicrophone
    {
      return
        "\(preferredMicrophone.name) is unavailable. System Default is active until it reconnects."
    }
    if let preferredMicrophone {
      return
        "Both Dictation Actions use \(preferredMicrophone.name) without changing the system default."
    }
    return "Both Dictation Actions follow this Mac’s system input."
  }

  /// Marks a retained but disconnected preference without hiding it.
  func microphoneTitle(_ microphone: PreferredMicrophone) -> String {
    guard
      availableMicrophones.contains(where: {
        $0.uniqueID == microphone.id
      })
    else {
      return "\(microphone.name) — Unavailable"
    }
    return microphone.name
  }

  /// Installs the process callback after application composition completes.
  func setMicrophoneSelectionHandler(
    _ handler: @escaping (String?) -> Void
  ) {
    microphoneSelectionHandler = handler
  }

  /// Installs the process callback after application composition completes.
  func setLocalAISettingsHandler(
    _ handler: @escaping (LocalAISettings) -> Void
  ) {
    localAISettingsHandler = handler
  }

  /// Installs the process callback after application composition completes.
  func setVoiceTriggerSettingsHandler(
    _ handler: @escaping (VoiceTriggerSettings) -> Void
  ) {
    voiceTriggerSettingsHandler = handler
  }

  /// Installs the History maintenance callback after composition completes.
  func setVoiceHistoryRetentionHandler(
    _ handler: @escaping (VoiceHistoryRetentionSettings) -> Void
  ) {
    voiceHistoryRetentionHandler = handler
  }

  /// Refreshes the local Device list without changing the saved preference.
  func refreshMicrophones() {
    do {
      availableMicrophones = try microphoneDiscovery.availableInputDevices()
      microphoneDiscoveryError = nil
    } catch {
      availableMicrophones = []
      microphoneDiscoveryError =
        "Microphones could not be listed: \(error.localizedDescription)"
    }
  }

  /// Persists one selection before applying it to process-owned capture.
  @discardableResult
  func setPreferredMicrophone(uniqueID: String?) -> Bool {
    let selected: PreferredMicrophone?
    if let uniqueID {
      if let device = availableMicrophones.first(where: {
        $0.uniqueID == uniqueID
      }) {
        selected = PreferredMicrophone(device: device)
      } else if preferredMicrophone?.id == uniqueID {
        selected = preferredMicrophone
      } else {
        return false
      }
    } else {
      selected = nil
    }
    guard selected != preferredMicrophone else {
      return true
    }
    var candidate = preferences
    candidate.preferredMicrophone = selected
    return persist(candidate) { [weak self] in
      self?.microphoneSelectionHandler?(selected?.id)
    }
  }

  /// Persists one complete Local AI configuration before applying it.
  @discardableResult
  func setLocalAISettings(_ settings: LocalAISettings) -> Bool {
    guard settings != preferences.localAI else {
      return true
    }
    do {
      try settings.validate()
    } catch {
      lastError = "Local AI Dictation settings are invalid: \(error)"
      return false
    }
    var candidate = preferences
    candidate.localAI = settings
    return persist(candidate) { [weak self] in
      self?.localAISettingsHandler?(settings)
    }
  }

  /// Persists one Voice trigger configuration before registering it.
  @discardableResult
  func setVoiceTriggerSettings(_ settings: VoiceTriggerSettings) -> Bool {
    guard settings != preferences.voiceTrigger else {
      return true
    }
    do {
      try settings.validate()
    } catch {
      lastError = "Voice capture shortcut settings are invalid: \(error)"
      return false
    }
    var candidate = preferences
    candidate.voiceTrigger = settings
    return persist(candidate) { [weak self] in
      self?.voiceTriggerSettingsHandler?(settings)
    }
  }

  /// Persists validated caps before applying them to local History storage.
  @discardableResult
  func setVoiceHistoryRetention(
    _ settings: VoiceHistoryRetentionSettings
  ) -> Bool {
    guard settings != preferences.voiceHistoryRetention else {
      return true
    }
    do {
      _ = try settings.validated()
    } catch {
      lastError = "Voice History retention settings are invalid: \(error)"
      return false
    }
    var candidate = preferences
    candidate.voiceHistoryRetention = settings
    return persist(candidate) { [weak self] in
      self?.voiceHistoryRetentionHandler?(settings)
    }
  }

  /// Persists and applies one app-wide appearance atomically.
  func setAppearance(_ appearance: ApplicationAppearance) {
    guard appearance != preferences.appearance else {
      return
    }
    var candidate = preferences
    candidate.appearance = appearance
    _ = persist(candidate) { [weak self] in
      self?.appearanceApplier?.apply(appearance)
    }
  }

  /// Persists the user's explicit sidebar visibility choice.
  func setSidebarVisibility(
    _ visibility: SidebarVisibilityPreference
  ) -> Bool {
    guard visibility != preferences.sidebarVisibility else {
      return true
    }
    var candidate = preferences
    candidate.sidebarVisibility = visibility
    return persist(candidate) {}
  }

  /// Clears current preference notices.
  func clearNotice() {
    lastError = nil
    recoveryNotice = nil
  }

  /// Persists before publishing any new effective preference.
  private func persist(
    _ candidate: ApplicationPreferences,
    apply: () -> Void
  ) -> Bool {
    do {
      try store.save(candidate)
      preferences = candidate
      lastError = nil
      apply()
      return true
    } catch {
      lastError =
        "Your application preferences could not be saved: \(error.localizedDescription)"
      return false
    }
  }

  /// Creates a live store or a deterministic failing fallback.
  private static func makeStore() -> any ApplicationPreferencesPersisting {
    do {
      return try ApplicationPreferencesStore.applicationSupportStore()
    } catch {
      return UnavailableApplicationPreferencesStore(error: error)
    }
  }

  /// Converts preference recovery state into concise presentation copy.
  private static func notice(
    for issue: ApplicationPreferencesStoreIssue?
  ) -> String? {
    switch issue {
    case .couldNotReadFile(let message):
      "Your application preferences could not be read: \(message)"
    case .requiresNewerApp(let schemaVersion):
      "These application preferences require a newer Hardware Controller (schema \(schemaVersion)). They were not changed."
    case .recoveredInvalidFile(
      let backupURL,
      let backupFailureMessage
    ):
      if let backupURL {
        "Invalid application preferences were preserved at \(backupURL.lastPathComponent). Defaults are active."
      } else if let backupFailureMessage {
        "Invalid application preferences were reset, but could not be preserved: \(backupFailureMessage)"
      } else {
        "Invalid application preferences were reset."
      }
    case nil:
      nil
    }
  }
}

/// Fails explicitly when the Application Support location is unavailable.
private struct UnavailableApplicationPreferencesStore:
  ApplicationPreferencesPersisting
{
  let error: any Error & Sendable

  /// Reports the unavailable store without touching disk.
  func load() -> ApplicationPreferencesLoadResult {
    ApplicationPreferencesLoadResult(
      preferences: .default,
      issue: .couldNotReadFile(message: error.localizedDescription)
    )
  }

  /// Preserves the original store-construction failure.
  func save(_ preferences: ApplicationPreferences) throws {
    throw error
  }
}

/// Isolates file-system operations for deterministic preference tests.
protocol ApplicationPreferencesFileAccessing: Sendable {
  /// Reports whether the preference file exists.
  func fileExists(at url: URL) -> Bool

  /// Reads one complete preference file.
  func read(from url: URL) throws -> Data

  /// Creates the parent preference directory.
  func createDirectory(at url: URL) throws

  /// Writes one complete file atomically.
  func write(_ data: Data, to url: URL) throws

  /// Copies invalid input without removing the original.
  func copyItem(at source: URL, to destination: URL) throws
}

/// Uses Foundation's local and atomic file operations.
private struct LocalApplicationPreferencesFileAccess:
  ApplicationPreferencesFileAccessing
{
  /// Reports whether one local path exists.
  func fileExists(at url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  /// Reads one local file.
  func read(from url: URL) throws -> Data {
    try Data(contentsOf: url)
  }

  /// Creates one local directory hierarchy.
  func createDirectory(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
  }

  /// Atomically replaces one local file.
  func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
  }

  /// Copies one local file for recovery.
  func copyItem(at source: URL, to destination: URL) throws {
    try FileManager.default.copyItem(
      at: source,
      to: destination
    )
  }
}
