import Foundation
import HardwareControllerVoiceCore
import Synchronization
import XCTest

@testable import VoiceInput

final class VoiceInputHistoryModelTest: XCTestCase {
  @MainActor
  func testRefreshAndSearchReplaceVisibleSessions() async throws {
    let recent = try Self.session(text: "Recent thought", endedAt: 20)
    let match = try Self.session(text: "Matched thought", endedAt: 10)
    let history = RecordingHistoryAccess(recent: [recent], search: [match])
    let model = VoiceInputHistoryModel(history: history)

    await model.refresh()
    model.query = "matched"
    await model.search()

    XCTAssertEqual(model.sessions, [match])
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(history.queries, ["matched"])
  }

  @MainActor
  func testUnavailableHistorySurfacesTheInitializationFailure() async {
    let model = VoiceInputHistoryModel(
      history: nil,
      initializationError: "History could not be opened."
    )

    await model.refresh()

    XCTAssertEqual(model.sessions, [])
    XCTAssertEqual(model.errorMessage, "History could not be opened.")
  }

  @MainActor
  func testRetentionChangePersistsBeforeApplyingMaintenance() async {
    let history = RecordingHistoryAccess(recent: [], search: [])
    let preferences = RecordingRetentionPreferences()
    let model = VoiceInputHistoryModel(
      history: history,
      retentionSettings: .iOSDefault,
      retentionPreferences: preferences
    )
    let settings = VoiceHistoryRetentionSettings(
      maximumAgeDays: 30,
      maximumAudioBytes: 512 * 1_024 * 1_024,
      maximumArtifactCount: 500
    )

    await model.updateRetentionSettings(settings)

    XCTAssertEqual(model.retentionSettings, settings)
    XCTAssertEqual(preferences.writes, [settings])
    XCTAssertEqual(history.retentionSettings, [settings])
    XCTAssertFalse(model.isUpdatingRetention)
    XCTAssertNil(model.errorMessage)
  }

  @MainActor
  func testUnsupportedRetentionPreferenceRemainsVisibleAndReadOnly() async {
    let history = RecordingHistoryAccess(recent: [], search: [])
    let model = VoiceInputHistoryModel(
      history: history,
      retentionSettings: .iOSDefault,
      retentionPreferences: nil,
      retentionInitializationError: "Settings require a newer app."
    )

    await model.refresh()

    XCTAssertFalse(model.canUpdateRetention)
    XCTAssertEqual(
      model.maintenanceMessage,
      "Settings require a newer app."
    )
  }

  @MainActor
  func testPinActionUsesTheTypedHistoryBoundary() async throws {
    let session = try Self.session(text: "Pin me", endedAt: 20)
    let history = RecordingHistoryAccess(recent: [session], search: [])
    let model = VoiceInputHistoryModel(history: history)

    await model.setPinned(sessionID: session.id, isPinned: true)

    XCTAssertEqual(
      history.pinUpdates,
      [PinUpdate(sessionID: session.id, isPinned: true)]
    )
    XCTAssertNil(model.errorMessage)
  }

  private static func session(
    text: String,
    endedAt: TimeInterval
  ) throws -> VoiceInputHistorySession {
    let raw = VoiceInputRawTranscript(
      text: text,
      segments: [],
      modelPackageID: "whisper",
      modelVersion: "1"
    )
    let processed = try VoiceInputDocumentPipeline().process(raw, style: .natural)
    return VoiceInputHistorySession(
      id: UUID(),
      startedAt: Date(timeIntervalSince1970: endedAt - 1),
      endedAt: Date(timeIntervalSince1970: endedAt),
      transcript: processed,
      audioArtifact: nil
    )
  }
}

private final class RecordingHistoryAccess: VoiceInputHistoryAccessing, Sendable {
  private struct State: Sendable {
    var queries: [String] = []
    var pinUpdates: [PinUpdate] = []
    var retentionSettings: [VoiceHistoryRetentionSettings] = []
  }

  private let recentSessions: [VoiceInputHistorySession]
  private let searchSessions: [VoiceInputHistorySession]
  private let state = Mutex(State())

  init(
    recent: [VoiceInputHistorySession],
    search: [VoiceInputHistorySession]
  ) {
    recentSessions = recent
    searchSessions = search
  }

  var queries: [String] { state.withLock { $0.queries } }
  var pinUpdates: [PinUpdate] { state.withLock { $0.pinUpdates } }
  var retentionSettings: [VoiceHistoryRetentionSettings] {
    state.withLock { $0.retentionSettings }
  }

  func recent(limit _: Int) async throws -> [VoiceInputHistorySession] {
    recentSessions
  }

  func search(
    query: String,
    limit _: Int
  ) async throws -> [VoiceInputHistorySession] {
    state.withLock { $0.queries.append(query) }
    return searchSessions
  }

  func enforceRetention(now: Date) async throws -> VoiceHistoryRetentionPlan {
    try VoiceHistoryRetentionPlanner.plan(
      candidates: [],
      settings: .unlimited,
      now: now
    )
  }

  func setRetentionSettings(
    _ settings: VoiceHistoryRetentionSettings,
    now: Date
  ) async throws -> VoiceHistoryRetentionPlan {
    state.withLock { $0.retentionSettings.append(settings) }
    return try VoiceHistoryRetentionPlanner.plan(
      candidates: [],
      settings: settings,
      now: now
    )
  }

  func setPinned(
    sessionID: UUID,
    isPinned: Bool
  ) async throws -> VoiceInputHistorySession {
    state.withLock {
      $0.pinUpdates.append(
        PinUpdate(sessionID: sessionID, isPinned: isPinned)
      )
    }
    guard
      let session = (recentSessions + searchSessions).first(where: {
        $0.id == sessionID
      })
    else {
      throw VoiceInputHistoryError.invalidSession
    }
    return session.settingPinned(isPinned)
  }

  func retentionMaintenanceMessage() async -> String? {
    nil
  }
}

private struct PinUpdate: Equatable, Sendable {
  let sessionID: UUID
  let isPinned: Bool
}

@MainActor
private final class RecordingRetentionPreferences:
  VoiceInputHistoryRetentionPreferenceStoring
{
  private(set) var writes: [VoiceHistoryRetentionSettings] = []

  func read() throws -> VoiceHistoryRetentionSettings {
    writes.last ?? .iOSDefault
  }

  func write(_ settings: VoiceHistoryRetentionSettings) throws {
    writes.append(settings)
  }
}
