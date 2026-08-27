import CryptoKit
import Foundation

public struct VoiceHistoryArchiveLimits: Equatable, Sendable {
  public static let standard = VoiceHistoryArchiveLimits(
    maximumManifestBytes: 16 * 1_024 * 1_024,
    maximumChecksumBytes: 256 * 1_024,
    maximumAudioBytes: 2 * 1_024 * 1_024 * 1_024,
    maximumResultCount: 10_000
  )

  public let maximumManifestBytes: Int64
  public let maximumChecksumBytes: Int64
  public let maximumAudioBytes: Int64
  public let maximumResultCount: Int

  public init(
    maximumManifestBytes: Int64,
    maximumChecksumBytes: Int64,
    maximumAudioBytes: Int64,
    maximumResultCount: Int
  ) {
    self.maximumManifestBytes = maximumManifestBytes
    self.maximumChecksumBytes = maximumChecksumBytes
    self.maximumAudioBytes = maximumAudioBytes
    self.maximumResultCount = maximumResultCount
  }
}

public enum VoiceHistoryArchiveError:
  Error,
  Equatable,
  LocalizedError,
  Sendable
{
  case invalidArchive
  case unsupportedSchema
  case sizeLimitExceeded
  case integrityCheckFailed
  case conflictingSession

  public var errorDescription: String? {
    switch self {
    case .invalidArchive:
      "This is not a valid Voice History archive."
    case .unsupportedSchema:
      "This Voice History archive requires a newer app."
    case .sizeLimitExceeded:
      "This Voice History archive exceeds the configured import limit."
    case .integrityCheckFailed:
      "This Voice History archive changed after it was exported."
    case .conflictingSession:
      "Voice History already contains different evidence with this session identifier."
    }
  }
}

public enum VoiceHistoryArchiveImportDisposition: Equatable, Sendable {
  case imported
  case alreadyPresent
}

public struct VoiceHistoryArchiveImportOutcome: Equatable, Sendable {
  public let sessionID: UUID
  public let disposition: VoiceHistoryArchiveImportDisposition

  public init(
    sessionID: UUID,
    disposition: VoiceHistoryArchiveImportDisposition
  ) {
    self.sessionID = sessionID
    self.disposition = disposition
  }
}

public protocol VoiceHistoryArchiveImporting: Sendable {
  func importArchive(from sourceURL: URL) async throws
    -> VoiceHistoryArchiveImportOutcome
}

public actor VoiceHistoryArchiveImporter: VoiceHistoryArchiveImporting {
  private let history: any VoiceSessionHistoryAccessing & VoiceSessionHistoryArchiveRestoring
  private let limits: VoiceHistoryArchiveLimits

  public init(
    history:
      any VoiceSessionHistoryAccessing & VoiceSessionHistoryArchiveRestoring,
    limits: VoiceHistoryArchiveLimits = .standard
  ) {
    self.history = history
    self.limits = limits
  }

  public func importArchive(
    from sourceURL: URL
  ) async throws -> VoiceHistoryArchiveImportOutcome {
    try validateLimits()
    let stagedRoot = FileManager.default.temporaryDirectory.appending(
      path: ".voice_history_import_\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: stagedRoot) }
    let inventory = try stageArchive(from: sourceURL, to: stagedRoot)
    let checksumData = try read(
      inventory.checksums,
      maximumBytes: limits.maximumChecksumBytes
    )
    let manifestData = try read(
      inventory.manifest,
      maximumBytes: limits.maximumManifestBytes
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let checksums: VoiceHistoryExportChecksums
    let manifest: VoiceHistoryArchiveManifest
    do {
      try validateTopLevelKeys(
        checksumData,
        allowed: ["schemaRevision", "algorithm", "files"]
      )
      try validateTopLevelKeys(
        manifestData,
        allowed: inventory.manifestFilename == "manifest.json"
          ? [
            "format", "schemaRevision", "exportedAt", "document", "results",
            "audioFilename", "audioDurationMilliseconds", "audioExpiredAt",
            "audioExpirationReason", "recoveryKind", "recoveredAt", "isPinned",
          ]
          : [
            "schemaRevision", "exportedAt", "document", "results",
            "audioFilename", "audioDurationMilliseconds", "audioExpiredAt",
            "audioExpirationReason", "recoveryKind", "recoveredAt", "isPinned",
          ]
      )
      checksums = try decoder.decode(
        VoiceHistoryExportChecksums.self,
        from: checksumData
      )
      manifest = try decodeManifest(
        manifestData,
        filename: inventory.manifestFilename,
        decoder: decoder
      )
    } catch let error as VoiceHistoryArchiveError {
      throw error
    } catch {
      throw VoiceHistoryArchiveError.invalidArchive
    }
    guard
      checksums.schemaRevision
        == VoiceHistoryExportChecksums.currentSchemaRevision
    else {
      throw VoiceHistoryArchiveError.unsupportedSchema
    }
    guard checksums.algorithm == "SHA-256" else {
      throw VoiceHistoryArchiveError.invalidArchive
    }
    try validateInventory(
      inventory,
      manifest: manifest,
      checksums: checksums
    )
    guard manifest.results.count <= limits.maximumResultCount else {
      throw VoiceHistoryArchiveError.sizeLimitExceeded
    }
    guard
      try checksum(at: inventory.manifest)
        == checksums.files[inventory.manifestFilename]
    else {
      throw VoiceHistoryArchiveError.integrityCheckFailed
    }
    if let audio = inventory.audio {
      guard try fileSize(at: audio) <= limits.maximumAudioBytes else {
        throw VoiceHistoryArchiveError.sizeLimitExceeded
      }
      guard try checksum(at: audio) == checksums.files["audio.caf"] else {
        throw VoiceHistoryArchiveError.integrityCheckFailed
      }
    }
    let archived = VoiceSessionHistoryItem(
      document: manifest.document,
      audioArtifactURL: inventory.audio,
      audioDurationMilliseconds: manifest.audioDurationMilliseconds,
      audioExpiredAt: manifest.audioExpiredAt,
      audioExpirationReason: manifest.audioExpirationReason,
      recoveryKind: manifest.recoveryKind,
      recoveredAt: manifest.recoveredAt,
      isPinned: manifest.isPinned,
      results: manifest.results
    )
    if let existing = try await history.session(id: archived.id) {
      guard try equivalent(existing, archived, checksums: checksums) else {
        throw VoiceHistoryArchiveError.conflictingSession
      }
      return VoiceHistoryArchiveImportOutcome(
        sessionID: archived.id,
        disposition: .alreadyPresent
      )
    }
    try await history.restoreArchive(archived)
    return VoiceHistoryArchiveImportOutcome(
      sessionID: archived.id,
      disposition: .imported
    )
  }

  private func validateLimits() throws {
    guard
      limits.maximumManifestBytes > 0,
      limits.maximumChecksumBytes > 0,
      limits.maximumAudioBytes >= 0,
      limits.maximumResultCount > 0
    else {
      throw VoiceHistoryArchiveError.sizeLimitExceeded
    }
  }

  private func archiveInventory(at root: URL) throws -> ArchiveInventory {
    let rootValues = try root.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
      throw VoiceHistoryArchiveError.invalidArchive
    }
    let entries = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [
        .isRegularFileKey,
        .isSymbolicLinkKey,
      ]
    )
    let names = Set(entries.map(\.lastPathComponent))
    let allowed = Set([
      "manifest.json", "session.json", "checksums.json", "audio.caf",
    ])
    let manifests = names.intersection(Set(["manifest.json", "session.json"]))
    guard
      names.isSubset(of: allowed),
      manifests.count == 1,
      names.contains("checksums.json")
    else {
      throw VoiceHistoryArchiveError.invalidArchive
    }
    for entry in entries {
      let values = try entry.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw VoiceHistoryArchiveError.invalidArchive
      }
    }
    guard let manifestFilename = manifests.first else {
      throw VoiceHistoryArchiveError.invalidArchive
    }
    return ArchiveInventory(
      manifest: root.appending(path: manifestFilename),
      manifestFilename: manifestFilename,
      checksums: root.appending(path: "checksums.json"),
      audio: names.contains("audio.caf")
        ? root.appending(path: "audio.caf") : nil
    )
  }

  /// Moves validation and restore onto an importer-owned immutable snapshot.
  private func stageArchive(
    from source: URL,
    to destination: URL
  ) throws -> ArchiveInventory {
    let sourceInventory = try archiveInventory(at: source)
    let audioWithinLimit: Bool
    if let audio = sourceInventory.audio {
      audioWithinLimit = try fileSize(at: audio) <= limits.maximumAudioBytes
    } else {
      audioWithinLimit = true
    }
    guard
      try fileSize(at: sourceInventory.manifest)
        <= limits.maximumManifestBytes,
      try fileSize(at: sourceInventory.checksums)
        <= limits.maximumChecksumBytes,
      audioWithinLimit
    else {
      throw VoiceHistoryArchiveError.sizeLimitExceeded
    }
    do {
      try FileManager.default.createDirectory(
        at: destination,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.copyItem(
        at: sourceInventory.manifest,
        to: destination.appending(path: sourceInventory.manifestFilename)
      )
      try FileManager.default.copyItem(
        at: sourceInventory.checksums,
        to: destination.appending(path: "checksums.json")
      )
      if let audio = sourceInventory.audio {
        try FileManager.default.copyItem(
          at: audio,
          to: destination.appending(path: "audio.caf")
        )
      }
      return try archiveInventory(at: destination)
    } catch let error as VoiceHistoryArchiveError {
      throw error
    } catch {
      throw VoiceHistoryArchiveError.invalidArchive
    }
  }

  private func validateInventory(
    _ inventory: ArchiveInventory,
    manifest: VoiceHistoryArchiveManifest,
    checksums: VoiceHistoryExportChecksums
  ) throws {
    let expectedFiles = Set(
      [inventory.manifestFilename]
        + (inventory.audio == nil ? [] : ["audio.caf"])
    )
    guard
      Set(checksums.files.keys) == expectedFiles,
      checksums.files.values.allSatisfy(isLowercaseSHA256),
      (manifest.audioFilename == "audio.caf") == (inventory.audio != nil),
      manifest.audioFilename == nil || manifest.audioFilename == "audio.caf",
      inventory.audio == nil || manifest.audioDurationMilliseconds != nil,
      manifest.results.allSatisfy({
        $0.sessionID == manifest.document.id
      })
    else {
      throw VoiceHistoryArchiveError.invalidArchive
    }
  }

  private func read(_ url: URL, maximumBytes: Int64) throws -> Data {
    guard try fileSize(at: url) <= maximumBytes else {
      throw VoiceHistoryArchiveError.sizeLimitExceeded
    }
    do {
      return try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
      throw VoiceHistoryArchiveError.invalidArchive
    }
  }

  private func decodeManifest(
    _ data: Data,
    filename: String,
    decoder: JSONDecoder
  ) throws -> VoiceHistoryArchiveManifest {
    switch filename {
    case "manifest.json":
      let manifest = try decoder.decode(
        VoiceHistoryArchiveManifest.self,
        from: data
      )
      guard
        manifest.format == "voice_history",
        manifest.schemaRevision
          == VoiceHistoryArchiveManifest.currentSchemaRevision
      else {
        throw VoiceHistoryArchiveError.unsupportedSchema
      }
      return manifest
    case "session.json":
      let legacy = try decoder.decode(
        LegacyVoiceHistoryArchiveManifest.self,
        from: data
      )
      guard
        legacy.schemaRevision
          == LegacyVoiceHistoryArchiveManifest.supportedSchemaRevision
      else {
        throw VoiceHistoryArchiveError.unsupportedSchema
      }
      return legacy.portableManifest
    default:
      throw VoiceHistoryArchiveError.invalidArchive
    }
  }

  private func validateTopLevelKeys(
    _ data: Data,
    allowed: Set<String>
  ) throws {
    let value = try JSONSerialization.jsonObject(with: data)
    guard
      let object = value as? [String: Any],
      Set(object.keys).isSubset(of: allowed)
    else {
      throw VoiceHistoryArchiveError.invalidArchive
    }
  }

  private func fileSize(at url: URL) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard let size = values.fileSize, size >= 0 else {
      throw VoiceHistoryArchiveError.invalidArchive
    }
    return Int64(size)
  }

  private func checksum(at url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map {
      String(format: "%02x", $0)
    }.joined()
  }

  private func equivalent(
    _ existing: VoiceSessionHistoryItem,
    _ archived: VoiceSessionHistoryItem,
    checksums: VoiceHistoryExportChecksums
  ) throws -> Bool {
    guard
      existing.document == archived.document,
      existing.audioDurationMilliseconds == archived.audioDurationMilliseconds,
      existing.recoveryKind == archived.recoveryKind,
      existing.recoveredAt == archived.recoveredAt,
      existing.results.starts(with: archived.results)
    else {
      return false
    }
    guard
      let existingAudio = existing.audioArtifactURL,
      archived.audioArtifactURL != nil
    else {
      return true
    }
    return try checksum(at: existingAudio) == checksums.files["audio.caf"]
  }

  private func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}

private struct ArchiveInventory {
  let manifest: URL
  let manifestFilename: String
  let checksums: URL
  let audio: URL?
}
