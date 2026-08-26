import Foundation
import HardwareControllerCore
import SQLite3
import Testing

@testable import HardwareControllerMac

struct SQLiteVoiceSessionStoreTest {
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
}
