import Foundation
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

  func enforceRetention(now _: Date) async throws {}
}
