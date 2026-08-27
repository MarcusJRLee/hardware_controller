import CryptoKit
import Foundation
import HardwareControllerCore

struct VoiceHistoryArchiveManifest: Codable, Equatable, Sendable {
  static let currentSchemaRevision = 1

  let format: String
  let schemaRevision: Int
  let exportedAt: Date
  let document: VoiceSessionDocument
  let results: [VoiceHistoryResult]
  let audioFilename: String?
  let audioDurationMilliseconds: Int64?
  let audioExpiredAt: Date?
  let audioExpirationReason: VoiceHistoryAudioExpirationReason?
  let recoveryKind: VoiceHistoryRecoveryKind?
  let recoveredAt: Date?
  let isPinned: Bool
}

/// Reads the final pre-portable export revision for one-way archive migration.
struct LegacyVoiceHistoryArchiveManifest: Codable, Equatable, Sendable {
  static let supportedSchemaRevision = 4

  let schemaRevision: Int
  let exportedAt: Date
  let document: VoiceSessionDocument
  let results: [VoiceHistoryResult]
  let audioFilename: String?
  let audioDurationMilliseconds: Int64?
  let audioExpiredAt: Date?
  let audioExpirationReason: VoiceHistoryAudioExpirationReason?
  let recoveryKind: VoiceHistoryRecoveryKind?
  let recoveredAt: Date?
  let isPinned: Bool

  var portableManifest: VoiceHistoryArchiveManifest {
    VoiceHistoryArchiveManifest(
      format: "voice_history",
      schemaRevision: VoiceHistoryArchiveManifest.currentSchemaRevision,
      exportedAt: exportedAt,
      document: document,
      results: results,
      audioFilename: audioFilename,
      audioDurationMilliseconds: audioDurationMilliseconds,
      audioExpiredAt: audioExpiredAt,
      audioExpirationReason: audioExpirationReason,
      recoveryKind: recoveryKind,
      recoveredAt: recoveredAt,
      isPinned: isPinned
    )
  }
}

struct VoiceHistoryExportChecksums: Codable, Equatable, Sendable {
  static let currentSchemaRevision = 1

  let schemaRevision: Int
  let algorithm: String
  let files: [String: String]
}

public protocol VoiceHistoryExporting: Sendable {
  func export(
    _ session: VoiceSessionHistoryItem,
    to destination: URL
  ) async throws
}

public actor VoiceHistoryExporter: VoiceHistoryExporting {
  private let now: @Sendable () -> Date

  public init(
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.now = now
  }

  /// Atomically writes one portable package without changing its source session.
  public func export(
    _ session: VoiceSessionHistoryItem,
    to destination: URL
  ) async throws {
    let fileManager = FileManager.default
    let partial = destination.deletingLastPathComponent()
      .appending(
        path: ".\(destination.lastPathComponent).partial_\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    defer { try? fileManager.removeItem(at: partial) }
    try fileManager.createDirectory(
      at: partial,
      withIntermediateDirectories: false
    )
    let audioFilename = session.audioArtifactURL.map { _ in "audio.caf" }
    let manifest = VoiceHistoryArchiveManifest(
      format: "voice_history",
      schemaRevision: VoiceHistoryArchiveManifest.currentSchemaRevision,
      exportedAt: now(),
      document: session.document,
      results: session.results,
      audioFilename: audioFilename,
      audioDurationMilliseconds: session.audioDurationMilliseconds,
      audioExpiredAt: session.audioExpiredAt,
      audioExpirationReason: session.audioExpirationReason,
      recoveryKind: session.recoveryKind,
      recoveredAt: session.recoveredAt,
      isPinned: session.isPinned
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let sessionURL = partial.appending(path: "manifest.json")
    try encoder.encode(manifest).write(
      to: sessionURL,
      options: [.atomic]
    )
    var exportedFiles = ["manifest.json": sessionURL]
    if let audioURL = session.audioArtifactURL {
      let exportedAudioURL = partial.appending(path: "audio.caf")
      try fileManager.copyItem(
        at: audioURL,
        to: exportedAudioURL
      )
      exportedFiles["audio.caf"] = exportedAudioURL
    }
    var checksums: [String: String] = [:]
    for filename in exportedFiles.keys.sorted() {
      if let url = exportedFiles[filename] {
        checksums[filename] = try checksum(at: url)
      }
    }
    try encoder.encode(
      VoiceHistoryExportChecksums(
        schemaRevision: VoiceHistoryExportChecksums.currentSchemaRevision,
        algorithm: "SHA-256",
        files: checksums
      )
    ).write(
      to: partial.appending(path: "checksums.json"),
      options: [.atomic]
    )
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(
        destination,
        withItemAt: partial
      )
    } else {
      try fileManager.moveItem(at: partial, to: destination)
    }
  }

  private func checksum(at url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576),
      !chunk.isEmpty
    {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map {
      String(format: "%02x", $0)
    }.joined()
  }
}
