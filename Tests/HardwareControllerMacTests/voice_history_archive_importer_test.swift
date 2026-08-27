import CryptoKit
import Foundation
import HardwareControllerCore
import HardwareControllerVoiceFFI
import Testing

@testable import HardwareControllerMac

struct VoiceHistoryArchiveImporterTest {
  @Test
  func sharedPortableFixtureRestoresThroughSwift() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "voice_archive_shared_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try SQLiteVoiceSessionHistory(rootDirectory: root)

    let outcome = try await VoiceHistoryArchiveImporter(history: history)
      .importArchive(from: sharedArchiveFixture())

    #expect(
      outcome.sessionID
        == UUID(uuidString: "00000000-0000-4000-8000-000000000001")
    )
    #expect(try await history.session(id: outcome.sessionID)?.results.count == 4)
  }

  @Test
  func portableVerifierFailureNeverMutatesHistory() async throws {
    let fixture = try ArchiveImportFixture()
    defer { fixture.remove() }
    let source = try await fixture.exportSource().url
    let importer = VoiceHistoryArchiveImporter(
      history: fixture.destination,
      portableValidator: RejectingPortableArchiveValidator()
    )

    await #expect(throws: VoiceHistoryArchiveError.invalidArchive) {
      try await importer.importArchive(from: source)
    }
    #expect(try await fixture.destination.recentSessions(limit: 10).isEmpty)
  }

  @Test
  func exportedArchiveRestoresAllEvidenceAndAudio() async throws {
    let fixture = try ArchiveImportFixture()
    defer { fixture.remove() }
    let exported = try await fixture.exportSource()
    let importer = VoiceHistoryArchiveImporter(history: fixture.destination)

    let outcome = try await importer.importArchive(from: exported.url)

    #expect(outcome.disposition == .imported)
    let restored = try #require(
      try await fixture.destination.session(id: fixture.sessionID)
    )
    #expect(restored.document == fixture.document)
    #expect(restored.results == exported.item.results)
    #expect(restored.isPinned)
    #expect(restored.audioDurationMilliseconds == 100)
    #expect(restored.audioArtifactURL != nil)
    #expect(
      restored.audioArtifactURL?.deletingLastPathComponent().path
        == fixture.destinationRoot.appending(path: "audio").path
    )
  }

  @Test
  func repeatedIdenticalArchiveImportIsIdempotent() async throws {
    let fixture = try ArchiveImportFixture()
    defer { fixture.remove() }
    let source = try await fixture.exportSource().url
    let importer = VoiceHistoryArchiveImporter(history: fixture.destination)

    _ = try await importer.importArchive(from: source)
    let repeated = try await importer.importArchive(from: source)

    #expect(repeated.disposition == .alreadyPresent)
    #expect(try await fixture.destination.recentSessions(limit: 10).count == 1)
  }

  @Test
  func repeatedImportPreservesNewerLocalPinState() async throws {
    let fixture = try ArchiveImportFixture()
    defer { fixture.remove() }
    let source = try await fixture.exportSource().url
    let importer = VoiceHistoryArchiveImporter(history: fixture.destination)
    _ = try await importer.importArchive(from: source)
    try await fixture.destination.setPinned(
      sessionID: fixture.sessionID,
      isPinned: false
    )

    let repeated = try await importer.importArchive(from: source)

    #expect(repeated.disposition == .alreadyPresent)
    #expect(
      try await fixture.destination.session(id: fixture.sessionID)?.isPinned
        == false
    )
  }

  @Test
  func prePortableRevisionFourArchiveMigratesOnImport() async throws {
    let fixture = try ArchiveImportFixture()
    defer { fixture.remove() }
    let source = try await fixture.exportSource().url
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let portableData = try Data(
      contentsOf: source.appending(path: "manifest.json")
    )
    let portable = try decoder.decode(
      VoiceHistoryArchiveManifest.self,
      from: portableData
    )
    let legacy = LegacyVoiceHistoryArchiveManifest(
      schemaRevision: 4,
      exportedAt: portable.exportedAt,
      document: portable.document,
      results: portable.results,
      audioFilename: portable.audioFilename,
      audioDurationMilliseconds: portable.audioDurationMilliseconds,
      audioExpiredAt: portable.audioExpiredAt,
      audioExpirationReason: portable.audioExpirationReason,
      recoveryKind: portable.recoveryKind,
      recoveredAt: portable.recoveredAt,
      isPinned: portable.isPinned
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let legacyData = try encoder.encode(legacy)
    try legacyData.write(to: source.appending(path: "session.json"))
    try FileManager.default.removeItem(
      at: source.appending(path: "manifest.json")
    )
    let checksumData = try Data(
      contentsOf: source.appending(path: "checksums.json")
    )
    let oldChecksums = try decoder.decode(
      VoiceHistoryExportChecksums.self,
      from: checksumData
    )
    var files = oldChecksums.files
    files["manifest.json"] = nil
    files["session.json"] = SHA256.hash(data: legacyData).map {
      String(format: "%02x", $0)
    }.joined()
    try encoder.encode(
      VoiceHistoryExportChecksums(
        schemaRevision: 1,
        algorithm: "SHA-256",
        files: files
      )
    ).write(to: source.appending(path: "checksums.json"))

    let outcome = try await VoiceHistoryArchiveImporter(
      history: fixture.destination
    ).importArchive(from: source)

    #expect(outcome.disposition == .imported)
    #expect(
      try await fixture.destination.session(id: fixture.sessionID)?.document
        == fixture.document
    )
  }

  @Test
  func alteredArchiveNeverMutatesHistory() async throws {
    let fixture = try ArchiveImportFixture()
    defer { fixture.remove() }
    let source = try await fixture.exportSource().url
    try Data("altered".utf8).write(
      to: source.appending(path: "audio.caf"),
      options: .atomic
    )
    let importer = VoiceHistoryArchiveImporter(history: fixture.destination)

    await #expect(throws: VoiceHistoryArchiveError.integrityCheckFailed) {
      try await importer.importArchive(from: source)
    }
    #expect(try await fixture.destination.recentSessions(limit: 10).isEmpty)
  }

  @Test
  func configuredAudioCapRejectsBeforeHistoryMutation() async throws {
    let fixture = try ArchiveImportFixture()
    defer { fixture.remove() }
    let source = try await fixture.exportSource().url
    let importer = VoiceHistoryArchiveImporter(
      history: fixture.destination,
      limits: VoiceHistoryArchiveLimits(
        maximumManifestBytes: 1_048_576,
        maximumChecksumBytes: 65_536,
        maximumAudioBytes: 1,
        maximumResultCount: 100
      )
    )

    await #expect(throws: VoiceHistoryArchiveError.sizeLimitExceeded) {
      try await importer.importArchive(from: source)
    }
    #expect(try await fixture.destination.recentSessions(limit: 10).isEmpty)
  }

  @Test
  func undeclaredFileRejectsBeforeHistoryMutation() async throws {
    let fixture = try ArchiveImportFixture()
    defer { fixture.remove() }
    let source = try await fixture.exportSource().url
    try Data("unexpected".utf8).write(
      to: source.appending(path: "notes.txt")
    )

    await #expect(throws: VoiceHistoryArchiveError.invalidArchive) {
      try await VoiceHistoryArchiveImporter(history: fixture.destination)
        .importArchive(from: source)
    }
    #expect(try await fixture.destination.recentSessions(limit: 10).isEmpty)
  }

  @Test
  func linkedArchiveEntryRejectsBeforeHistoryMutation() async throws {
    let fixture = try ArchiveImportFixture()
    defer { fixture.remove() }
    let source = try await fixture.exportSource().url
    let audio = source.appending(path: "audio.caf")
    let linkedTarget = fixture.root.appending(path: "linked_audio.caf")
    try FileManager.default.moveItem(at: audio, to: linkedTarget)
    try FileManager.default.createSymbolicLink(
      at: audio,
      withDestinationURL: linkedTarget
    )

    await #expect(throws: VoiceHistoryArchiveError.invalidArchive) {
      try await VoiceHistoryArchiveImporter(history: fixture.destination)
        .importArchive(from: source)
    }
    #expect(try await fixture.destination.recentSessions(limit: 10).isEmpty)
  }

  @Test
  func sameIdentifierWithDifferentEvidenceRejectsAsConflict() async throws {
    let fixture = try ArchiveImportFixture()
    defer { fixture.remove() }
    let source = try await fixture.exportSource().url
    let importer = VoiceHistoryArchiveImporter(history: fixture.destination)
    _ = try await importer.importArchive(from: source)
    let conflictingRoot = fixture.root.appending(path: "conflict")
    let conflicting = try SQLiteVoiceSessionHistory(
      rootDirectory: conflictingRoot
    )
    let different = VoiceSessionDocument(
      id: fixture.sessionID,
      startedAt: fixture.document.startedAt,
      endedAt: fixture.document.endedAt,
      rawText: "different",
      editedText: "different",
      formattedText: "Different.",
      deliveredText: "Different.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted
    )
    conflicting.begin(
      sessionID: fixture.sessionID,
      startedAt: different.startedAt
    )
    conflicting.append(try makeVoiceAudioFixture())
    try await conflicting.complete(different)
    let conflictingItem = try #require(
      try await conflicting.session(id: fixture.sessionID)
    )
    let conflictingArchive = fixture.root.appending(
      path: "conflict.voice_history"
    )
    try await VoiceHistoryExporter().export(
      conflictingItem,
      to: conflictingArchive
    )

    await #expect(throws: VoiceHistoryArchiveError.conflictingSession) {
      try await importer.importArchive(from: conflictingArchive)
    }
    #expect(
      try await fixture.destination.session(id: fixture.sessionID)?.document
        == fixture.document
    )
  }
}

private struct RejectingPortableArchiveValidator:
  PortableVoiceHistoryArchiveValidating
{
  func validateHistoryArchive(
    at _: URL,
    limits _: PortableVoiceValidationLimits
  ) throws -> PortableVoiceHistoryArchive {
    throw PortableVoiceValidationError.internalFailure
  }
}

private func sharedArchiveFixture() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "cuj/voice_history_archive_v1/valid")
}

private final class ArchiveImportFixture: Sendable {
  let root: URL
  let sourceRoot: URL
  let destinationRoot: URL
  let source: SQLiteVoiceSessionHistory
  let destination: SQLiteVoiceSessionHistory
  let sessionID = UUID()
  let document: VoiceSessionDocument

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "voice_archive_import_\(UUID().uuidString)")
    sourceRoot = root.appending(path: "source")
    destinationRoot = root.appending(path: "destination")
    source = try SQLiteVoiceSessionHistory(rootDirectory: sourceRoot)
    destination = try SQLiteVoiceSessionHistory(rootDirectory: destinationRoot)
    document = VoiceSessionDocument(
      id: sessionID,
      startedAt: Date(timeIntervalSince1970: 1_000),
      endedAt: Date(timeIntervalSince1970: 1_001),
      rawText: "raw",
      editedText: "edited",
      formattedText: "Formatted.",
      deliveredText: "Formatted.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted
    )
  }

  func exportSource() async throws -> (url: URL, item: VoiceSessionHistoryItem) {
    source.begin(sessionID: sessionID, startedAt: document.startedAt)
    source.append(try makeVoiceAudioFixture())
    try await source.complete(document)
    try await source.setPinned(sessionID: sessionID, isPinned: true)
    let item = try #require(try await source.session(id: sessionID))
    let archive = root.appending(path: "source.voice_history")
    try await VoiceHistoryExporter(
      now: { Date(timeIntervalSince1970: 2_000) }
    ).export(item, to: archive)
    return (archive, item)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
