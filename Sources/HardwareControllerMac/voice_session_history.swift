import Foundation
import HardwareControllerCore
import OSLog
import Synchronization

private let voiceHistoryLogger = Logger(
  subsystem: ApplicationIdentity.bundleIdentifier,
  category: "voice_history"
)

public enum VoiceSessionHistoryError:
  Error,
  Equatable,
  LocalizedError,
  Sendable
{
  case invalidLimit
  case invalidResult(String)
  case sessionNotFound
  case storageUnavailable(String)
  case audioUnavailable(String)

  public var errorDescription: String? {
    switch self {
    case .invalidLimit:
      "History queries require a limit from 1 through 1,000."
    case .invalidResult(let detail):
      detail
    case .sessionNotFound:
      "The Voice History session no longer exists."
    case .storageUnavailable(let detail),
      .audioUnavailable(let detail):
      detail
    }
  }
}

public struct VoiceSessionHistoryItem:
  Equatable,
  Identifiable,
  Sendable
{
  public let document: VoiceSessionDocument
  public let audioArtifactURL: URL?
  public let audioDurationMilliseconds: Int64?
  public let audioExpiredAt: Date?
  public let audioExpirationReason: VoiceHistoryAudioExpirationReason?
  public let recoveryKind: VoiceHistoryRecoveryKind?
  public let recoveredAt: Date?
  public let isPinned: Bool
  public let results: [VoiceHistoryResult]

  public init(
    document: VoiceSessionDocument,
    audioArtifactURL: URL?,
    audioDurationMilliseconds: Int64? = nil,
    audioExpiredAt: Date? = nil,
    audioExpirationReason: VoiceHistoryAudioExpirationReason? = nil,
    recoveryKind: VoiceHistoryRecoveryKind? = nil,
    recoveredAt: Date? = nil,
    isPinned: Bool = false,
    results: [VoiceHistoryResult] = []
  ) {
    self.document = document
    self.audioArtifactURL = audioArtifactURL
    self.audioDurationMilliseconds = audioDurationMilliseconds
    self.audioExpiredAt = audioExpiredAt
    self.audioExpirationReason = audioExpirationReason
    self.recoveryKind = recoveryKind
    self.recoveredAt = recoveredAt
    self.isPinned = isPinned
    self.results = results
  }

  public var id: UUID { document.id }
  public var rawText: String { document.rawText }
  public var editedText: String { document.editedText }
  public var formattedText: String { document.formattedText }
  public var deliveredText: String { document.deliveredText }
  public var formattedDocument: VoiceFormattedDocument? {
    document.formattedDocument
  }
  public var deliveryOutcome: VoiceSessionDeliveryOutcome {
    document.deliveryOutcome
  }
}

public enum VoiceHistoryRetentionIssue: Equatable, Sendable {
  case missingArtifact(sessionID: UUID)
  case unreadableArtifactSize(sessionID: UUID)
  case removalFailed(sessionID: UUID)
  case lowDiskShortfall(bytes: Int64)
  case byteLimitUnmet(bytes: Int64)
  case artifactLimitUnmet(count: Int)
  case maintenanceUnavailable(String)
}

public struct VoiceHistoryRetentionReport: Equatable, Sendable {
  public let completedAt: Date
  public let expired: [VoiceHistoryRetentionDecision]
  public let issues: [VoiceHistoryRetentionIssue]

  public init(
    completedAt: Date,
    expired: [VoiceHistoryRetentionDecision],
    issues: [VoiceHistoryRetentionIssue]
  ) {
    self.completedAt = completedAt
    self.expired = expired
    self.issues = issues
  }
}

public enum VoiceHistoryRecoveryRuntimeIssue: Equatable, Sendable {
  case unreadableArtifact(filename: String)
  case actionFailed(filename: String)
  case invalidSessionRecord
  case databaseRebuilt(preservedFilename: String)
}

public struct VoiceHistoryRecoveryReport: Equatable, Sendable {
  public let completedAt: Date
  public let completedActions: [VoiceHistoryRecoveryAction]
  public let issues: [VoiceHistoryRecoveryRuntimeIssue]

  public init(
    completedAt: Date,
    completedActions: [VoiceHistoryRecoveryAction],
    issues: [VoiceHistoryRecoveryRuntimeIssue]
  ) {
    self.completedAt = completedAt
    self.completedActions = completedActions
    self.issues = issues
  }
}

public protocol VoiceSessionHistoryAccessing: Sendable {
  func recentSessions(limit: Int) async throws
    -> [VoiceSessionHistoryItem]

  func searchSessions(query: String, limit: Int) async throws
    -> [VoiceSessionHistoryItem]

  func session(id: UUID) async throws -> VoiceSessionHistoryItem?

  func appendResult(_ result: VoiceHistoryResult) async throws

  func setPinned(sessionID: UUID, isPinned: Bool) async throws

  func deleteSession(id: UUID) async throws
}

public protocol VoiceSessionHistoryRecording: Sendable {
  /// Opens one recording before the microphone can produce its first buffer.
  func begin(sessionID: UUID, startedAt: Date)

  /// Enqueues immutable audio without waiting on filesystem work.
  func append(_ audio: CapturedAudioBuffer)

  /// Finalizes audio before atomically storing the completed document.
  func complete(_ document: VoiceSessionDocument) async throws

  /// Discards an explicitly canceled session.
  func cancel(sessionID: UUID) async
}

public protocol VoiceSessionHistoryRetentionManaging: Sendable {
  /// Applies validated caps immediately and to future completed sessions.
  func setRetentionSettings(
    _ settings: VoiceHistoryRetentionSettings
  ) async throws -> VoiceHistoryRetentionReport

  /// Reclaims eligible audio using the normal deterministic ordering.
  func reclaimForLowDisk(bytes: Int64) async throws
    -> VoiceHistoryRetentionReport

  /// Returns the latest maintenance evidence without running maintenance.
  func latestRetentionReport() -> VoiceHistoryRetentionReport?
}

public protocol VoiceSessionHistoryRecoveryManaging: Sendable {
  /// Returns the latest startup-reconciliation evidence without rerunning it.
  func latestRecoveryReport() -> VoiceHistoryRecoveryReport?
}

public protocol VoiceSessionHistoryManaging:
  VoiceSessionHistoryRecording,
  VoiceSessionHistoryAccessing,
  VoiceSessionHistoryRetentionManaging,
  VoiceSessionHistoryRecoveryManaging
{}

public struct DiscardingVoiceSessionHistory:
  VoiceSessionHistoryRecording
{
  public init() {}

  public func begin(sessionID: UUID, startedAt: Date) {}
  public func append(_ audio: CapturedAudioBuffer) {}
  public func complete(_ document: VoiceSessionDocument) async throws {}
  public func cancel(sessionID: UUID) async {}
}

public struct UnavailableVoiceSessionHistory:
  VoiceSessionHistoryManaging
{
  private let failure: VoiceSessionHistoryError

  public init(failure: VoiceSessionHistoryError) {
    self.failure = failure
  }

  public func begin(sessionID: UUID, startedAt: Date) {}
  public func append(_ audio: CapturedAudioBuffer) {}

  public func complete(_ document: VoiceSessionDocument) async throws {
    throw failure
  }

  public func cancel(sessionID: UUID) async {}

  public func recentSessions(limit: Int) async throws
    -> [VoiceSessionHistoryItem]
  {
    throw failure
  }

  public func searchSessions(query: String, limit: Int) async throws
    -> [VoiceSessionHistoryItem]
  {
    throw failure
  }

  public func session(id: UUID) async throws -> VoiceSessionHistoryItem? {
    throw failure
  }

  public func appendResult(_ result: VoiceHistoryResult) async throws {
    throw failure
  }

  public func setPinned(sessionID: UUID, isPinned: Bool) async throws {
    throw failure
  }

  public func deleteSession(id: UUID) async throws {
    throw failure
  }

  public func setRetentionSettings(
    _ settings: VoiceHistoryRetentionSettings
  ) async throws -> VoiceHistoryRetentionReport {
    throw failure
  }

  public func reclaimForLowDisk(bytes: Int64) async throws
    -> VoiceHistoryRetentionReport
  {
    throw failure
  }

  public func latestRetentionReport() -> VoiceHistoryRetentionReport? {
    nil
  }

  public func latestRecoveryReport() -> VoiceHistoryRecoveryReport? {
    nil
  }
}

public final class SQLiteVoiceSessionHistory:
  VoiceSessionHistoryManaging,
  Sendable
{
  private struct ActiveRecording {
    let sessionID: UUID
    let recorder: any VoiceAudioArtifactRecording
  }

  typealias RecorderFactory =
    @Sendable (UUID, URL) ->
    any VoiceAudioArtifactRecording

  private let state = Mutex<ActiveRecording?>(nil)
  struct RetentionState {
    var settings: VoiceHistoryRetentionSettings
    var revision: UInt64 = 1
    var lastEnforcedRevision: UInt64?
    var latestReport: VoiceHistoryRetentionReport?

    /// Prevents an older maintenance task from replacing newer evidence.
    mutating func record(
      _ report: VoiceHistoryRetentionReport,
      for enforcedRevision: UInt64,
      markEnforced: Bool
    ) {
      guard revision == enforcedRevision else {
        return
      }
      if markEnforced {
        lastEnforcedRevision = enforcedRevision
      }
      latestReport = report
    }
  }

  private let retentionState: Mutex<RetentionState>
  private let recoveryState = Mutex<VoiceHistoryRecoveryReport?>(nil)
  private let store: SQLiteVoiceSessionStore
  private let retentionStore: SQLiteVoiceHistoryRetentionStore
  private let reconciler: VoiceHistoryReconciler
  private let audioDirectory: URL
  private let recorderFactory: RecorderFactory

  public convenience init(rootDirectory: URL) throws {
    try self.init(
      rootDirectory: rootDirectory,
      retentionSettings: .unlimited
    )
  }

  public convenience init(
    rootDirectory: URL,
    retentionSettings: VoiceHistoryRetentionSettings
  ) throws {
    try self.init(
      rootDirectory: rootDirectory,
      retentionSettings: retentionSettings,
      recorderFactory: { sessionID, audioDirectory in
        VoiceAudioArtifactRecorder(
          sessionID: sessionID,
          audioDirectory: audioDirectory
        )
      }
    )
  }

  init(
    rootDirectory: URL,
    retentionSettings: VoiceHistoryRetentionSettings,
    recorderFactory: @escaping RecorderFactory
  ) throws {
    let retentionSettings = try retentionSettings.validated()
    retentionState = Mutex(
      RetentionState(settings: retentionSettings)
    )
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: rootDirectory,
        withIntermediateDirectories: true
      )
      var excludedRootDirectory = rootDirectory
      var backupValues = URLResourceValues()
      backupValues.isExcludedFromBackup = true
      do {
        try excludedRootDirectory.setResourceValues(backupValues)
      } catch {
        voiceHistoryLogger.error(
          "Voice History backup exclusion could not be applied."
        )
      }
      let audioDirectory = rootDirectory.appending(
        path: "audio",
        directoryHint: .isDirectory
      )
      try fileManager.createDirectory(
        at: audioDirectory,
        withIntermediateDirectories: true
      )
      self.audioDirectory = audioDirectory
      let databaseURL = rootDirectory.appending(path: "history.sqlite3")
      let preservedDatabase = try VoiceHistoryDatabaseRecovery.prepare(
        databaseURL: databaseURL
      )
      store = try SQLiteVoiceSessionStore(
        databaseURL: databaseURL,
        audioDirectory: audioDirectory
      )
      retentionStore = try SQLiteVoiceHistoryRetentionStore(
        databaseURL: databaseURL,
        audioDirectory: audioDirectory
      )
      reconciler = VoiceHistoryReconciler(
        store: store,
        audioDirectory: audioDirectory
      )
      self.recorderFactory = recorderFactory
      if let preservedDatabase {
        recoveryState.withLock { report in
          report = VoiceHistoryRecoveryReport(
            completedAt: Date(),
            completedActions: [],
            issues: [
              .databaseRebuilt(
                preservedFilename: preservedDatabase
              )
            ]
          )
        }
      }
    } catch let failure as VoiceSessionHistoryError {
      throw failure
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not open its local storage."
      )
    }
  }

  public static func applicationSupportHistory(
    retentionSettings: VoiceHistoryRetentionSettings = .macOSDefault
  ) throws
    -> SQLiteVoiceSessionHistory
  {
    let root = try ApplicationIdentity.applicationSupportDirectory()
      .appending(path: "voice", directoryHint: .isDirectory)
    return try SQLiteVoiceSessionHistory(
      rootDirectory: root,
      retentionSettings: retentionSettings
    )
  }

  public func begin(sessionID: UUID, startedAt: Date) {
    let recorder = recorderFactory(sessionID, audioDirectory)
    let replaced = state.withLock { current in
      let replaced = current
      current = ActiveRecording(
        sessionID: sessionID,
        recorder: recorder
      )
      return replaced
    }
    replaced?.recorder.stopRetainingAudio()
  }

  public func append(_ audio: CapturedAudioBuffer) {
    let recorder = state.withLock { $0?.recorder }
    recorder?.append(audio)
  }

  public func complete(_ document: VoiceSessionDocument) async throws {
    let recorder: (any VoiceAudioArtifactRecording)? = state.withLock { current in
      guard current?.sessionID == document.id else {
        return nil
      }
      defer { current = nil }
      return current?.recorder
    }
    let audioURL: URL?
    do {
      audioURL = try await recorder?.finishRetainingAudio()
    } catch let audioFailure as VoiceSessionHistoryError {
      try await store.insert(document, audioURL: nil)
      invalidateRetention()
      scheduleRetention()
      throw audioFailure
    }
    try await store.insert(document, audioURL: audioURL)
    invalidateRetention()
    scheduleRetention()
  }

  public func cancel(sessionID: UUID) async {
    let recorder: (any VoiceAudioArtifactRecording)? = state.withLock { current in
      guard current?.sessionID == sessionID else {
        return nil
      }
      defer { current = nil }
      return current?.recorder
    }
    await recorder?.discard()
  }

  public func recentSessions(
    limit: Int
  ) async throws -> [VoiceSessionHistoryItem] {
    try await prepareAtStartupIfNeeded()
    let sessions = try await store.recentSessions(limit: limit)
    await recordInvalidSessionIssues()
    return sessions
  }

  public func searchSessions(
    query: String,
    limit: Int
  ) async throws -> [VoiceSessionHistoryItem] {
    try await prepareAtStartupIfNeeded()
    let sessions = try await store.searchSessions(query: query, limit: limit)
    await recordInvalidSessionIssues()
    return sessions
  }

  public func session(id: UUID) async throws
    -> VoiceSessionHistoryItem?
  {
    try await prepareAtStartupIfNeeded()
    let session = try await store.session(id: id)
    await recordInvalidSessionIssues()
    return session
  }

  public func appendResult(_ result: VoiceHistoryResult) async throws {
    try await store.appendResult(result)
  }

  public func setPinned(
    sessionID: UUID,
    isPinned: Bool
  ) async throws {
    try await store.setPinned(
      sessionID: sessionID,
      isPinned: isPinned
    )
    invalidateRetention()
    if !isPinned {
      await enforceAfterMutation()
    }
  }

  public func deleteSession(id: UUID) async throws {
    try await store.deleteSession(id: id)
    invalidateRetention()
    scheduleRetention()
  }

  public func setRetentionSettings(
    _ settings: VoiceHistoryRetentionSettings
  ) async throws -> VoiceHistoryRetentionReport {
    let settings = try settings.validated()
    let revision = retentionState.withLock { state in
      state.settings = settings
      state.revision &+= 1
      return state.revision
    }
    return try await enforce(
      settings: settings,
      revision: revision,
      lowDiskReclaimBytes: 0
    )
  }

  public func reclaimForLowDisk(bytes: Int64) async throws
    -> VoiceHistoryRetentionReport
  {
    let values = retentionState.withLock {
      ($0.settings, $0.revision)
    }
    return try await enforce(
      settings: values.0,
      revision: values.1,
      lowDiskReclaimBytes: bytes
    )
  }

  public func latestRetentionReport() -> VoiceHistoryRetentionReport? {
    retentionState.withLock(\.latestReport)
  }

  public func latestRecoveryReport() -> VoiceHistoryRecoveryReport? {
    recoveryState.withLock { $0 }
  }

  private func prepareAtStartupIfNeeded() async throws {
    try await reconcileAtStartupIfNeeded()
    try await enforceAtStartupIfNeeded()
  }

  private func reconcileAtStartupIfNeeded() async throws {
    if let report = try await reconciler.reconcileIfNeeded() {
      recoveryState.withLock { existing in
        let priorIssues = existing?.issues ?? []
        existing = VoiceHistoryRecoveryReport(
          completedAt: report.completedAt,
          completedActions: report.completedActions,
          issues: priorIssues
            + report.issues.filter {
              !priorIssues.contains($0)
            }
        )
      }
    }
  }

  private func recordInvalidSessionIssues() async {
    guard await store.consumeInvalidSessionRecordCount() > 0 else {
      return
    }
    recoveryState.withLock { report in
      let existing =
        report
        ?? VoiceHistoryRecoveryReport(
          completedAt: Date(),
          completedActions: [],
          issues: []
        )
      guard !existing.issues.contains(.invalidSessionRecord) else {
        return
      }
      report = VoiceHistoryRecoveryReport(
        completedAt: existing.completedAt,
        completedActions: existing.completedActions,
        issues: existing.issues + [.invalidSessionRecord]
      )
    }
  }

  private func enforceAtStartupIfNeeded() async throws {
    let values = retentionState.withLock { state in
      (
        state.settings,
        state.revision,
        state.lastEnforcedRevision == state.revision
      )
    }
    guard !values.2 else {
      return
    }
    _ = try await enforce(
      settings: values.0,
      revision: values.1,
      lowDiskReclaimBytes: 0
    )
  }

  private func invalidateRetention() {
    retentionState.withLock { state in
      state.revision &+= 1
      state.lastEnforcedRevision = nil
    }
  }

  private func scheduleRetention() {
    Task(priority: .utility) { [weak self] in
      await self?.enforceAfterMutation()
    }
  }

  private func enforceAfterMutation() async {
    let values = retentionState.withLock {
      ($0.settings, $0.revision)
    }
    do {
      _ = try await enforce(
        settings: values.0,
        revision: values.1,
        lowDiskReclaimBytes: 0
      )
    } catch {
      let report = VoiceHistoryRetentionReport(
        completedAt: Date(),
        expired: [],
        issues: [
          .maintenanceUnavailable(error.localizedDescription)
        ]
      )
      retentionState.withLock { state in
        state.record(report, for: values.1, markEnforced: false)
      }
    }
  }

  private func enforce(
    settings: VoiceHistoryRetentionSettings,
    revision: UInt64,
    lowDiskReclaimBytes: Int64
  ) async throws -> VoiceHistoryRetentionReport {
    try await reconcileAtStartupIfNeeded()
    let activeSessionIDs = state.withLock { active in
      active.map { Set([$0.sessionID]) } ?? []
    }
    let report = try await retentionStore.enforce(
      settings: settings,
      now: Date(),
      activeSessionIDs: activeSessionIDs,
      lowDiskReclaimBytes: lowDiskReclaimBytes
    )
    retentionState.withLock { state in
      state.record(report, for: revision, markEnforced: true)
    }
    return report
  }
}
