import Combine
import Foundation
import HardwareControllerVoiceCore

protocol VoiceInputHistoryAccessing: Sendable {
  func recent(limit: Int) async throws -> [VoiceInputHistorySession]
  func search(
    query: String,
    limit: Int
  ) async throws -> [VoiceInputHistorySession]
  func enforceRetention(now: Date) async throws -> VoiceHistoryRetentionPlan
  func setRetentionSettings(
    _ settings: VoiceHistoryRetentionSettings,
    now: Date
  ) async throws -> VoiceHistoryRetentionPlan
  func setPinned(
    sessionID: UUID,
    isPinned: Bool
  ) async throws -> VoiceInputHistorySession
  func retentionMaintenanceMessage() async -> String?
}

extension VoiceInputHistoryRepository: VoiceInputHistoryAccessing {}

@MainActor
final class VoiceInputHistoryModel: ObservableObject {
  @Published private(set) var sessions: [VoiceInputHistorySession] = []
  @Published var query = ""
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var maintenanceMessage: String?
  @Published private(set) var retentionSettings: VoiceHistoryRetentionSettings
  @Published private(set) var isUpdatingRetention = false

  private let history: (any VoiceInputHistoryAccessing)?
  private let initializationError: String?
  private let retentionPreferences: (any VoiceInputHistoryRetentionPreferenceStoring)?
  private let retentionInitializationError: String?
  private let resultLimit: Int

  var canUpdateRetention: Bool {
    history != nil && retentionPreferences != nil
  }

  init(
    history: (any VoiceInputHistoryAccessing)?,
    initializationError: String? = nil,
    retentionSettings: VoiceHistoryRetentionSettings = .iOSDefault,
    retentionPreferences: (any VoiceInputHistoryRetentionPreferenceStoring)? = nil,
    retentionInitializationError: String? = nil,
    resultLimit: Int = 100
  ) {
    self.history = history
    self.initializationError = initializationError
    self.retentionSettings = retentionSettings
    self.retentionPreferences = retentionPreferences
    self.retentionInitializationError = retentionInitializationError
    maintenanceMessage = retentionInitializationError
    self.resultLimit = resultLimit
  }

  func refresh() async {
    await load(searching: false)
  }

  func search() async {
    await load(searching: true)
  }

  func setPinned(
    sessionID: UUID,
    isPinned: Bool
  ) async {
    guard let history else {
      return
    }
    do {
      _ = try await history.setPinned(
        sessionID: sessionID,
        isPinned: isPinned
      )
      await load(searching: !query.isEmpty)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func updateRetentionSettings(
    _ settings: VoiceHistoryRetentionSettings
  ) async {
    guard
      let history,
      let retentionPreferences,
      !isUpdatingRetention
    else {
      return
    }
    isUpdatingRetention = true
    defer { isUpdatingRetention = false }
    do {
      let validated = try settings.validated()
      try retentionPreferences.write(validated)
      retentionSettings = validated
      _ = try await history.setRetentionSettings(validated, now: .now)
      setMaintenanceMessage(
        repositoryMessage: await history.retentionMaintenanceMessage()
      )
      try await reloadSessions(searching: !query.isEmpty, history: history)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func load(searching: Bool) async {
    guard let history else {
      sessions = []
      errorMessage = initializationError ?? "Local Voice History is unavailable."
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      _ = try await history.enforceRetention(now: .now)
      setMaintenanceMessage(
        repositoryMessage: await history.retentionMaintenanceMessage()
      )
    } catch {
      setMaintenanceMessage(
        repositoryMessage:
          await history.retentionMaintenanceMessage()
          ?? "History storage maintenance could not finish and will retry."
      )
    }
    do {
      try await reloadSessions(searching: searching, history: history)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func reloadSessions(
    searching: Bool,
    history: any VoiceInputHistoryAccessing
  ) async throws {
    sessions =
      searching
      ? try await history.search(query: query, limit: resultLimit)
      : try await history.recent(limit: resultLimit)
  }

  private func setMaintenanceMessage(repositoryMessage: String?) {
    maintenanceMessage = [retentionInitializationError, repositoryMessage]
      .compactMap { $0 }
      .joined(separator: " ")
    if maintenanceMessage?.isEmpty == true {
      maintenanceMessage = nil
    }
  }
}
