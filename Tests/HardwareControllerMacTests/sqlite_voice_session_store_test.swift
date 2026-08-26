import Foundation
import HardwareControllerCore
import SQLite3
import Testing

@testable import HardwareControllerMac

struct SQLiteVoiceSessionStoreTest {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "HC_RUN_VOICE_HISTORY_BENCHMARK"
      ] == "1"
    )
  )
  func searchesFiveThousandSessionsWithinTheWarmBudget() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_benchmark_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    var initialized: SQLiteVoiceSessionHistory? =
      try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    initialized = nil
    #expect(initialized == nil)
    var database: OpaquePointer?
    #expect(
      sqlite3_open(
        rootDirectory.appending(path: "history.sqlite3").path,
        &database
      ) == SQLITE_OK
    )
    let opened = try #require(database)
    var seed = "BEGIN IMMEDIATE;"
    for index in 0..<5_000 {
      let sessionID = UUID().uuidString
      let resultID = UUID().uuidString
      let text =
        index == 4_321
        ? "distinct needle phrase" : "ordinary session \(index)"
      seed += """
        INSERT INTO voice_sessions (
          id, started_at, ended_at, raw_text, edited_text,
          formatted_text, delivered_text, delivery_outcome, is_pinned
        ) VALUES (
          '\(sessionID)', \(index), \(index + 1), '\(text)', '\(text)',
          '\(text)', '\(text)', 'inserted', 0
        );
        INSERT INTO voice_results (
          id, session_id, created_at, stage, origin, text
        ) VALUES (
          '\(resultID)', '\(sessionID)', \(index + 1),
          'raw', 'capture', '\(text)'
        );
        """
    }
    seed += "COMMIT;"
    #expect(sqlite3_exec(opened, seed, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(opened)
    database = nil
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let clock = ContinuousClock()
    var samples: [Duration] = []
    var matches: [VoiceSessionHistoryItem] = []

    for _ in 0..<20 {
      let start = clock.now
      matches = try await history.searchSessions(
        query: "needle phrase",
        limit: 10
      )
      samples.append(start.duration(to: clock.now))
    }
    let ordered = samples.sorted()
    let p95 = ordered[18]
    print("Voice History 5,000-session warm-search p95: \(p95)")
    #expect(matches.count == 1)
    #expect(p95 <= .milliseconds(250))
  }

  @Test
  func baselineStagesRemainImmutableAndShareOneTimedAudioArtifact()
    async throws
  {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_results_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let sessionID = UUID()
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let document = try historyDocument(sessionID: sessionID)
    history.begin(sessionID: sessionID, startedAt: document.startedAt)
    history.append(try makeVoiceAudioFixture())

    try await history.complete(document)

    let session = try #require(
      try await history.session(id: sessionID)
    )
    #expect(
      session.results.map(\.stage) == [
        .raw, .edited, .formatted, .delivered,
      ])
    #expect(session.results[1].sourceResultID == session.results[0].id)
    #expect(session.results[2].sourceResultID == session.results[1].id)
    #expect(session.results[3].sourceResultID == session.results[2].id)
    #expect(session.results[2].style == .technical)
    #expect(session.results[2].provider == .ollama)
    #expect(session.results[2].modelIdentifier == "qwen3.5:4b")
    #expect(session.results[2].promptRevision == 5)
    #expect(session.audioDurationMilliseconds == 100)
    #expect(
      session.results[0].timedSpans
        == [
          VoiceHistoryTimedSpan(
            startMilliseconds: 0,
            endMilliseconds: 100,
            text: document.rawText
          )
        ]
    )
    #expect(session.isPinned == false)
    #expect(session.audioArtifactURL?.lastPathComponent == "\(sessionID).caf")
  }

  @Test
  func searchIncludesEveryStageAndAStoredCorrection() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_search_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let sessionID = UUID()
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let document = try historyDocument(sessionID: sessionID)
    history.begin(sessionID: sessionID, startedAt: document.startedAt)
    try await history.complete(document)
    let stored = try #require(try await history.session(id: sessionID))
    let source = try #require(stored.results.preferredReusableResult)
    let correction = VoiceHistoryResult(
      sessionID: sessionID,
      createdAt: Date(timeIntervalSince1970: 1_002),
      stage: .corrected,
      origin: .correction,
      text: "Corrected lunar wording.",
      sourceResultID: source.id
    )

    try await history.appendResult(correction)

    for query in ["raw nebula", "edited comet", "formatted orbit", "delivered star", "lunar"] {
      let matches = try await history.searchSessions(
        query: query,
        limit: 10
      )
      #expect(matches.map(\.id) == [sessionID])
    }
    #expect(
      try await history.searchSessions(query: "not present", limit: 10)
        .isEmpty
    )
    let reopened = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let result = try #require(
      try await reopened.session(id: sessionID)?.results.last
    )
    #expect(result == correction)
    #expect(
      try await reopened.session(id: sessionID)?.results.count == 5
    )
  }

  @Test
  func pinPersistsAndDeleteRemovesMetadataAndAudio() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_delete_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let sessionID = UUID()
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let document = try historyDocument(sessionID: sessionID)
    history.begin(sessionID: sessionID, startedAt: document.startedAt)
    history.append(try makeVoiceAudioFixture())
    try await history.complete(document)
    let audioURL = try #require(
      try await history.session(id: sessionID)?.audioArtifactURL
    )

    try await history.setPinned(sessionID: sessionID, isPinned: true)

    let reopened = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    #expect(try await reopened.session(id: sessionID)?.isPinned == true)
    try await reopened.deleteSession(id: sessionID)
    #expect(try await reopened.session(id: sessionID) == nil)
    #expect(!FileManager.default.fileExists(atPath: audioURL.path))
  }

  @Test
  func derivedTimingCannotEscapeTheImmutableAudio() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_timing_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let sessionID = UUID()
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let document = try historyDocument(sessionID: sessionID)
    history.begin(sessionID: sessionID, startedAt: document.startedAt)
    history.append(try makeVoiceAudioFixture())
    try await history.complete(document)
    let source = try #require(
      try await history.session(id: sessionID)?.results.first
    )
    let result = VoiceHistoryResult(
      sessionID: sessionID,
      createdAt: Date(timeIntervalSince1970: 1_100),
      stage: .raw,
      origin: .retranscription,
      text: "Too long",
      sourceResultID: source.id,
      timedSpans: [
        VoiceHistoryTimedSpan(
          startMilliseconds: 0,
          endMilliseconds: 101,
          text: "Too long"
        )
      ]
    )

    await #expect(throws: VoiceSessionHistoryError.self) {
      try await history.appendResult(result)
    }
  }

  @Test
  func contradictoryStoredResultProvenanceIsRejected() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_provenance_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let sessionID = UUID()
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let document = try historyDocument(sessionID: sessionID)
    history.begin(sessionID: sessionID, startedAt: document.startedAt)
    try await history.complete(document)
    _ = try await history.session(id: sessionID)
    var database: OpaquePointer?
    #expect(
      sqlite3_open(
        rootDirectory.appending(path: "history.sqlite3").path,
        &database
      ) == SQLITE_OK
    )
    let opened = try #require(database)
    #expect(
      sqlite3_exec(
        opened,
        "UPDATE voice_results SET origin = 'delivery' WHERE stage = 'raw';",
        nil,
        nil,
        nil
      ) == SQLITE_OK
    )
    sqlite3_close(opened)
    database = nil

    await #expect(throws: VoiceSessionHistoryError.self) {
      try await history.session(id: sessionID)
    }
  }

  @Test
  func brokenStoredResultRelationshipIsRejected() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_relationship_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let sessionID = UUID()
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    try await history.complete(try historyDocument(sessionID: sessionID))
    _ = try await history.session(id: sessionID)
    var database: OpaquePointer?
    #expect(
      sqlite3_open(
        rootDirectory.appending(path: "history.sqlite3").path,
        &database
      ) == SQLITE_OK
    )
    let opened = try #require(database)
    #expect(
      sqlite3_exec(
        opened,
        """
        UPDATE voice_results
        SET source_result_id = '\(UUID().uuidString)'
        WHERE stage = 'edited';
        """,
        nil,
        nil,
        nil
      ) == SQLITE_OK
    )
    sqlite3_close(opened)
    database = nil

    await #expect(throws: VoiceSessionHistoryError.self) {
      try await history.session(id: sessionID)
    }
  }

  @Test
  func deliveredResultWithoutOutcomeIsRejected() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_outcome_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let sessionID = UUID()
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    try await history.complete(try historyDocument(sessionID: sessionID))
    _ = try await history.session(id: sessionID)
    var database: OpaquePointer?
    #expect(
      sqlite3_open(
        rootDirectory.appending(path: "history.sqlite3").path,
        &database
      ) == SQLITE_OK
    )
    let opened = try #require(database)
    #expect(
      sqlite3_exec(
        opened,
        """
        UPDATE voice_results
        SET delivery_outcome = NULL
        WHERE stage = 'delivered';
        """,
        nil,
        nil,
        nil
      ) == SQLITE_OK
    )
    sqlite3_close(opened)
    database = nil

    await #expect(throws: VoiceSessionHistoryError.self) {
      try await history.session(id: sessionID)
    }
  }

  @Test
  func captureWaitsForAnotherHistoryWriter() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_writer_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let document = try historyDocument(sessionID: UUID())
    var database: OpaquePointer?
    #expect(
      sqlite3_open(
        rootDirectory.appending(path: "history.sqlite3").path,
        &database
      ) == SQLITE_OK
    )
    let opened = try #require(database)
    #expect(
      sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK
    )

    let completion = Task {
      try await history.complete(document)
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(sqlite3_exec(opened, "COMMIT;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(opened)
    database = nil
    try await completion.value

    #expect(try await history.session(id: document.id) != nil)
  }

  @Test
  func storedDocumentIsReadableFromAReopenedHistory() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_reopen_\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: rootDirectory)
    }
    let sessionID = UUID()
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let first = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory
    )
    let rawText =
      "wrong scratch that first install Git second run bash --version"
    let formattedDocument = try VoiceFormattedDocumentBuilder().build(
      formattedText: "1. Install Git.\n2. Run bash --version.",
      rawText: rawText,
      style: .technical,
      provider: .ollama,
      modelIdentifier: "qwen3.5:4b",
      promptRevision: 5
    )
    let spokenEdits = VoiceSpokenEditEngine().apply(
      to: rawText
    )
    first.begin(sessionID: sessionID, startedAt: startedAt)
    try await first.complete(
      VoiceSessionDocument(
        id: sessionID,
        startedAt: startedAt,
        endedAt: Date(timeIntervalSince1970: 1_001),
        rawText: rawText,
        editedText: spokenEdits.editedText,
        formattedText: "1. Install Git.\n2. Run bash --version.",
        deliveredText: "1. Install Git.\n2. Run bash --version.",
        targetApplicationName: "Notes",
        deliveryOutcome: .inserted,
        formattedDocument: formattedDocument,
        spokenEdits: spokenEdits
      )
    )

    let reopened = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory
    )
    let item = try #require(
      try await reopened.recentSessions(limit: 1).first
    )

    #expect(item.id == sessionID)
    #expect(
      item.formattedText
        == "1. Install Git.\n2. Run bash --version."
    )
    #expect(item.formattedDocument == formattedDocument)
    #expect(item.document.spokenEdits == spokenEdits)
    #expect(item.document.deliveryFailureReason == nil)
    #expect(
      try VoiceSpokenEditReplayer().replay(spokenEdits)
        == item.editedText
    )
    #expect(item.audioArtifactURL == nil)
  }

  @Test
  func legacyDatabaseAddsStructuredFormattingWithoutLosingRows()
    async throws
  {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_legacy_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    try FileManager.default.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true
    )
    let sessionID = UUID()
    var database: OpaquePointer?
    #expect(
      sqlite3_open(
        rootDirectory.appending(path: "history.sqlite3").path,
        &database
      ) == SQLITE_OK
    )
    let opened = try #require(database)
    defer {
      if let database {
        sqlite3_close(database)
      }
    }
    let sql = """
      CREATE TABLE voice_sessions (
        id TEXT PRIMARY KEY NOT NULL,
        started_at REAL NOT NULL,
        ended_at REAL NOT NULL,
        raw_text TEXT NOT NULL,
        edited_text TEXT NOT NULL,
        formatted_text TEXT NOT NULL,
        delivered_text TEXT NOT NULL,
        target_application_name TEXT,
        delivery_outcome TEXT NOT NULL,
        delivery_failure TEXT,
        audio_filename TEXT
      );
      INSERT INTO voice_sessions VALUES (
        '\(sessionID.uuidString)', 1000, 1001, 'raw', 'raw',
        'Raw.', 'Raw.', 'Notes', 'inserted', NULL, NULL
      );
      """
    #expect(sqlite3_exec(opened, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(opened)
    database = nil

    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let item = try #require(
      try await history.recentSessions(limit: 1).first
    )

    #expect(item.id == sessionID)
    #expect(item.rawText == "raw")
    #expect(item.formattedDocument == nil)
    #expect(item.document.spokenEdits == nil)
    #expect(item.document.deliveryFailureReason == nil)
  }

  @Test
  func legacySessionRemainsSearchableWhenItsAudioIsMissing()
    async throws
  {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_missing_audio_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    try FileManager.default.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true
    )
    let sessionID = UUID()
    var database: OpaquePointer?
    #expect(
      sqlite3_open(
        rootDirectory.appending(path: "history.sqlite3").path,
        &database
      ) == SQLITE_OK
    )
    let opened = try #require(database)
    let sql = """
      CREATE TABLE voice_sessions (
        id TEXT PRIMARY KEY NOT NULL,
        started_at REAL NOT NULL,
        ended_at REAL NOT NULL,
        raw_text TEXT NOT NULL,
        edited_text TEXT NOT NULL,
        formatted_text TEXT NOT NULL,
        delivered_text TEXT NOT NULL,
        target_application_name TEXT,
        delivery_outcome TEXT NOT NULL,
        delivery_failure TEXT,
        audio_filename TEXT
      );
      INSERT INTO voice_sessions VALUES (
        '\(sessionID.uuidString)', 1000, 1001, 'raw', 'raw',
        'Raw.', 'Raw.', 'Notes', 'inserted', NULL,
        '\(sessionID.uuidString).caf'
      );
      """
    #expect(sqlite3_exec(opened, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(opened)
    database = nil

    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let item = try #require(
      try await history.searchSessions(query: "Raw", limit: 1).first
    )

    #expect(item.id == sessionID)
    #expect(item.audioArtifactURL == nil)
    #expect(item.results.count == 4)
    #expect(item.results.first?.timedSpans.isEmpty == true)
  }

  @Test
  func typedOwnershipFailureSurvivesDatabaseReopen() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_ownership_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let sessionID = UUID()
    let first = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    first.begin(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 1_000)
    )
    try await first.complete(
      VoiceSessionDocument(
        id: sessionID,
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_001),
        rawText: "Keep this",
        editedText: "Keep this",
        formattedText: "Keep this.",
        deliveredText: "",
        targetApplicationName: "Notes",
        deliveryOutcome: .failed,
        deliveryFailure: "The target process changed.",
        deliveryFailureReason: .processChanged
      )
    )

    let reopened = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory
    )
    let item = try #require(
      try await reopened.recentSessions(limit: 1).first
    )

    #expect(item.document.deliveryFailureReason == .processChanged)
  }

  @Test
  func typedOwnershipFailureCannotContradictDeliveryEvidence() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_bad_ownership_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let document = VoiceSessionDocument(
      id: UUID(),
      startedAt: Date(timeIntervalSince1970: 1_000),
      endedAt: Date(timeIntervalSince1970: 1_001),
      rawText: "Keep this",
      editedText: "Keep this",
      formattedText: "Keep this.",
      deliveredText: "Keep this.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted,
      deliveryFailureReason: .processChanged
    )

    await #expect(throws: VoiceSessionHistoryError.self) {
      try await history.complete(document)
    }
    #expect(try await history.recentSessions(limit: 1).isEmpty)
  }

  @Test
  func mismatchedStructuredEvidenceIsNotStored() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_invalid_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let formattedDocument = try VoiceFormattedDocumentBuilder().build(
      formattedText: "Different.",
      rawText: "different raw",
      style: .natural
    )
    let document = VoiceSessionDocument(
      id: UUID(),
      startedAt: Date(timeIntervalSince1970: 1_000),
      endedAt: Date(timeIntervalSince1970: 1_001),
      rawText: "expected raw",
      editedText: "expected raw",
      formattedText: "Different.",
      deliveredText: "Different.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted,
      formattedDocument: formattedDocument
    )

    await #expect(throws: VoiceSessionHistoryError.self) {
      try await history.complete(document)
    }
    #expect(try await history.recentSessions(limit: 1).isEmpty)
  }

  @Test
  func mismatchedSpokenEditTraceIsNotStored() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
      .appending(path: "voice_history_invalid_edits_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let history = try SQLiteVoiceSessionHistory(rootDirectory: rootDirectory)
    let valid = VoiceSpokenEditEngine().apply(
      to: "Wrong scratch that Right"
    )
    let mismatched = VoiceSpokenEditResult(
      sourceText: valid.sourceText,
      editedText: "Changed",
      operations: valid.operations
    )
    let document = VoiceSessionDocument(
      id: UUID(),
      startedAt: Date(timeIntervalSince1970: 1_000),
      endedAt: Date(timeIntervalSince1970: 1_001),
      rawText: valid.sourceText,
      editedText: "Changed",
      formattedText: "Changed.",
      deliveredText: "Changed.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted,
      spokenEdits: mismatched
    )

    await #expect(throws: VoiceSessionHistoryError.self) {
      try await history.complete(document)
    }
    #expect(try await history.recentSessions(limit: 1).isEmpty)
  }

  @Test
  func expirationRemovesOnlyAudioAndPersistsItsReason() async throws {
    let rootDirectory = temporaryRoot("retention_metadata")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let sessionID = UUID()
    let history = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory,
      retentionSettings: .unlimited
    )
    let document = retentionDocument(sessionID: sessionID)
    history.begin(sessionID: sessionID, startedAt: document.startedAt)
    history.append(try makeVoiceAudioFixture())
    try await history.complete(document)
    let audioURL = try #require(
      try await history.session(id: sessionID)?.audioArtifactURL
    )

    let report = try await history.setRetentionSettings(
      VoiceHistoryRetentionSettings(
        maximumAgeDays: nil,
        maximumAudioBytes: nil,
        maximumArtifactCount: 0
      )
    )

    #expect(report.expired.map(\.sessionID) == [sessionID])
    #expect(report.expired.first?.reason == .artifactLimit)
    #expect(report.issues.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: audioURL.path))
    let retained = try #require(try await history.session(id: sessionID))
    #expect(retained.audioArtifactURL == nil)
    #expect(retained.audioDurationMilliseconds == 100)
    #expect(retained.audioExpirationReason == .artifactLimit)
    #expect(retained.audioExpiredAt != nil)
    #expect(retained.results.count == 4)
    #expect(
      try await history.searchSessions(query: "nebula", limit: 1).first?.id
        == sessionID
    )
  }

  @Test
  func zeroRetentionPreservesPinnedAndSoleRecoveryAudio() async throws {
    let rootDirectory = temporaryRoot("retention_protected")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let pinnedID = UUID()
    let recoveryID = UUID()
    let history = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory,
      retentionSettings: .unlimited
    )
    try await recordAudio(
      in: history,
      document: retentionDocument(sessionID: pinnedID)
    )
    try await history.setPinned(sessionID: pinnedID, isPinned: true)
    try await recordAudio(
      in: history,
      document: retentionDocument(
        sessionID: recoveryID,
        deliveryOutcome: .failed
      )
    )

    let report = try await history.setRetentionSettings(
      VoiceHistoryRetentionSettings(
        maximumAgeDays: 0,
        maximumAudioBytes: 0,
        maximumArtifactCount: 0
      )
    )

    #expect(report.expired.isEmpty)
    #expect(
      report.issues.contains(.artifactLimitUnmet(count: 2))
    )
    #expect(try await history.session(id: pinnedID)?.audioArtifactURL != nil)
    #expect(try await history.session(id: recoveryID)?.audioArtifactURL != nil)

    try await history.setPinned(sessionID: pinnedID, isPinned: false)

    #expect(try await history.session(id: pinnedID)?.audioArtifactURL == nil)
    #expect(
      try await history.session(id: pinnedID)?.audioExpirationReason
        == .ageLimit
    )
  }

  @Test
  func startupAndPostFinalizationEnforceConfiguredCaps() async throws {
    let rootDirectory = temporaryRoot("retention_startup")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    var seed: SQLiteVoiceSessionHistory? = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory,
      retentionSettings: .unlimited
    )
    let firstID = UUID()
    try await recordAudio(
      in: try #require(seed),
      document: retentionDocument(sessionID: firstID)
    )
    seed = nil
    let zeroAudio = VoiceHistoryRetentionSettings(
      maximumAgeDays: nil,
      maximumAudioBytes: nil,
      maximumArtifactCount: 0
    )
    let reopened = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory,
      retentionSettings: zeroAudio
    )

    #expect(try await reopened.recentSessions(limit: 1).count == 1)
    #expect(
      try await reopened.session(id: firstID)?.audioExpirationReason
        == .artifactLimit
    )

    let secondID = UUID()
    try await recordAudio(
      in: reopened,
      document: retentionDocument(sessionID: secondID)
    )
    #expect(
      try await reopened.session(id: secondID)?.audioExpirationReason
        == .artifactLimit
    )
  }

  @Test
  func maintenanceSkipsUnreadableSizeAndExpiresUnrelatedAudio()
    async throws
  {
    let rootDirectory = temporaryRoot("retention_corrupt_size")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let unreadableID = UUID()
    let eligibleID = UUID()
    var seed: SQLiteVoiceSessionHistory? = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory,
      retentionSettings: .unlimited
    )
    try await recordAudio(
      in: try #require(seed),
      document: retentionDocument(sessionID: unreadableID, secondsAgo: 2)
    )
    try await recordAudio(
      in: try #require(seed),
      document: retentionDocument(sessionID: eligibleID, secondsAgo: 1)
    )
    seed = nil
    let audioDirectory = rootDirectory.appending(path: "audio")
    let store = try SQLiteVoiceHistoryRetentionStore(
      databaseURL: rootDirectory.appending(path: "history.sqlite3"),
      audioDirectory: audioDirectory,
      artifactSize: { url in
        if url.lastPathComponent == "\(unreadableID.uuidString).caf" {
          return -1
        }
        return Int64(
          try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            ?? 0
        )
      }
    )

    let report = try await store.enforce(
      settings: VoiceHistoryRetentionSettings(
        maximumAgeDays: nil,
        maximumAudioBytes: nil,
        maximumArtifactCount: 0
      ),
      now: Date(),
      activeSessionIDs: [],
      lowDiskReclaimBytes: 0
    )

    #expect(report.expired.map(\.sessionID) == [eligibleID])
    #expect(
      report.issues.contains(
        .unreadableArtifactSize(sessionID: unreadableID)
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: audioDirectory.appending(
          path: "\(unreadableID.uuidString).caf"
        ).path
      )
    )
  }

  @Test
  func lowDiskReportsShortfallWithoutDeletingProtectedAudio() async throws {
    let rootDirectory = temporaryRoot("retention_low_disk")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let sessionID = UUID()
    let history = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory,
      retentionSettings: .unlimited
    )
    try await recordAudio(
      in: history,
      document: retentionDocument(
        sessionID: sessionID,
        deliveryOutcome: .failed
      )
    )

    let report = try await history.reclaimForLowDisk(bytes: 1_000)

    #expect(report.expired.isEmpty)
    #expect(report.issues == [.lowDiskShortfall(bytes: 1_000)])
    #expect(try await history.session(id: sessionID)?.audioArtifactURL != nil)
    await #expect(
      throws: VoiceHistoryRetentionValidationError.invalidReclaimRequest
    ) {
      try await history.reclaimForLowDisk(bytes: -1)
    }
  }

  @Test
  func concurrentFinalizationConvergesOnOneArtifact() async throws {
    let rootDirectory = temporaryRoot("retention_concurrent")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let settings = VoiceHistoryRetentionSettings(
      maximumAgeDays: nil,
      maximumAudioBytes: nil,
      maximumArtifactCount: 1
    )
    let first = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory,
      retentionSettings: settings
    )
    let second = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory,
      retentionSettings: settings
    )
    let firstDocument = retentionDocument(
      sessionID: UUID(),
      secondsAgo: 2
    )
    let secondDocument = retentionDocument(
      sessionID: UUID(),
      secondsAgo: 1
    )
    first.begin(
      sessionID: firstDocument.id,
      startedAt: firstDocument.startedAt
    )
    first.append(try makeVoiceAudioFixture())
    second.begin(
      sessionID: secondDocument.id,
      startedAt: secondDocument.startedAt
    )
    second.append(try makeVoiceAudioFixture())

    async let firstCompletion: Void = first.complete(firstDocument)
    async let secondCompletion: Void = second.complete(secondDocument)
    _ = try await (firstCompletion, secondCompletion)

    let reopened = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory,
      retentionSettings: .unlimited
    )
    var sessions: [VoiceSessionHistoryItem] = []
    for _ in 0..<100 {
      sessions = try await reopened.recentSessions(limit: 10)
      if sessions.filter({ $0.audioArtifactURL != nil }).count == 1 {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(sessions.count == 2)
    #expect(sessions.filter { $0.audioArtifactURL != nil }.count == 1)
    #expect(
      sessions.filter { $0.audioExpirationReason != nil }.count == 1
    )
  }

  @Test
  func retentionStateRejectsStaleMaintenanceEvidence() {
    let currentReport = VoiceHistoryRetentionReport(
      completedAt: Date(timeIntervalSince1970: 2),
      expired: [],
      issues: []
    )
    let staleReport = VoiceHistoryRetentionReport(
      completedAt: Date(timeIntervalSince1970: 1),
      expired: [],
      issues: [.maintenanceUnavailable("Stale failure.")]
    )
    var state = SQLiteVoiceSessionHistory.RetentionState(
      settings: .macOSDefault,
      revision: 2
    )

    state.record(currentReport, for: 2, markEnforced: true)
    state.record(staleReport, for: 1, markEnforced: false)

    #expect(state.lastEnforcedRevision == 2)
    #expect(state.latestReport == currentReport)
  }

  @Test
  func expirationRemainsOrderedAcrossWallClockRollback() async throws {
    let rootDirectory = temporaryRoot("retention_clock_rollback")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let sessionID = UUID()
    let document = retentionDocument(
      sessionID: sessionID,
      secondsAgo: -60
    )
    let history = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory,
      retentionSettings: .unlimited
    )
    try await recordAudio(in: history, document: document)

    _ = try await history.setRetentionSettings(
      VoiceHistoryRetentionSettings(
        maximumAgeDays: nil,
        maximumAudioBytes: nil,
        maximumArtifactCount: 0
      )
    )

    let retained = try #require(
      try await history.session(id: sessionID)
    )
    #expect(retained.audioExpiredAt.map { $0 >= document.endedAt } == true)
    #expect(retained.audioExpirationReason == .artifactLimit)
  }

  @Test
  func automaticLowDiskCleanupUsesTheSameRetentionPath() async throws {
    let rootDirectory = temporaryRoot("retention_automatic_low_disk")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    let sessionID = UUID()
    var seed: SQLiteVoiceSessionHistory? = try SQLiteVoiceSessionHistory(
      rootDirectory: rootDirectory,
      retentionSettings: .unlimited
    )
    try await recordAudio(
      in: try #require(seed),
      document: retentionDocument(sessionID: sessionID)
    )
    seed = nil
    let audioDirectory = rootDirectory.appending(path: "audio")
    let store = try SQLiteVoiceHistoryRetentionStore(
      databaseURL: rootDirectory.appending(path: "history.sqlite3"),
      audioDirectory: audioDirectory,
      availableCapacity: { _ in
        SQLiteVoiceHistoryRetentionStore.lowDiskReserveBytes - 1
      }
    )

    let report = try await store.enforce(
      settings: .unlimited,
      now: Date(),
      activeSessionIDs: [],
      lowDiskReclaimBytes: 0
    )

    #expect(report.expired.map(\.sessionID) == [sessionID])
    #expect(report.expired.first?.reason == .lowDisk)
    #expect(report.issues.isEmpty)
  }

  private func historyDocument(
    sessionID: UUID
  ) throws -> VoiceSessionDocument {
    let rawText = "raw nebula"
    let editedText = "edited comet"
    let formattedText = "Formatted orbit."
    let formattedDocument = try VoiceFormattedDocumentBuilder().build(
      formattedText: formattedText,
      rawText: rawText,
      style: .technical,
      provider: .ollama,
      modelIdentifier: "qwen3.5:4b",
      promptRevision: 5
    )
    return VoiceSessionDocument(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 1_000),
      endedAt: Date(timeIntervalSince1970: 1_001),
      rawText: rawText,
      editedText: editedText,
      formattedText: formattedText,
      deliveredText: "Delivered star.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted,
      formattedDocument: formattedDocument
    )
  }

  private func temporaryRoot(_ purpose: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "voice_history_\(purpose)_\(UUID().uuidString)"
    )
  }

  private func retentionDocument(
    sessionID: UUID,
    secondsAgo: TimeInterval = 0,
    deliveryOutcome: VoiceSessionDeliveryOutcome = .inserted
  ) -> VoiceSessionDocument {
    let endedAt = Date().addingTimeInterval(-secondsAgo)
    let failure = deliveryOutcome == .failed ? "Target changed." : nil
    return VoiceSessionDocument(
      id: sessionID,
      startedAt: endedAt.addingTimeInterval(-1),
      endedAt: endedAt,
      rawText: "raw nebula",
      editedText: "edited comet",
      formattedText: "Formatted orbit.",
      deliveredText:
        deliveryOutcome == .inserted ? "Delivered star." : "",
      targetApplicationName: "Notes",
      deliveryOutcome: deliveryOutcome,
      deliveryFailure: failure
    )
  }

  private func recordAudio(
    in history: SQLiteVoiceSessionHistory,
    document: VoiceSessionDocument
  ) async throws {
    history.begin(
      sessionID: document.id,
      startedAt: document.startedAt
    )
    history.append(try makeVoiceAudioFixture())
    try await history.complete(document)
  }
}
