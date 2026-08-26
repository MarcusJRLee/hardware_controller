import Foundation
import HardwareControllerCore
import Synchronization

public enum VoiceSessionHistoryError:
  Error,
  Equatable,
  LocalizedError,
  Sendable
{
  case invalidLimit
  case storageUnavailable(String)
  case audioUnavailable(String)

  public var errorDescription: String? {
    switch self {
    case .invalidLimit:
      "History queries require a limit from 1 through 1,000."
    case .storageUnavailable(let detail),
      .audioUnavailable(let detail):
      detail
    }
  }
}

public struct VoiceSessionHistoryItem: Equatable, Sendable {
  public let document: VoiceSessionDocument
  public let audioArtifactURL: URL?

  public var id: UUID { document.id }
  public var rawText: String { document.rawText }
  public var editedText: String { document.editedText }
  public var formattedText: String { document.formattedText }
  public var deliveredText: String { document.deliveredText }
  public var deliveryOutcome: VoiceSessionDeliveryOutcome {
    document.deliveryOutcome
  }
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
  VoiceSessionHistoryRecording
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
}

public final class SQLiteVoiceSessionHistory:
  VoiceSessionHistoryRecording,
  Sendable
{
  private struct ActiveRecording {
    let sessionID: UUID
    let recorder: VoiceAudioArtifactRecorder
  }

  private let state = Mutex<ActiveRecording?>(nil)
  private let store: SQLiteVoiceSessionStore
  private let audioDirectory: URL

  public init(rootDirectory: URL) throws {
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: rootDirectory,
        withIntermediateDirectories: true
      )
      let audioDirectory = rootDirectory.appending(
        path: "audio",
        directoryHint: .isDirectory
      )
      try fileManager.createDirectory(
        at: audioDirectory,
        withIntermediateDirectories: true
      )
      self.audioDirectory = audioDirectory
      store = try SQLiteVoiceSessionStore(
        databaseURL: rootDirectory.appending(path: "history.sqlite3"),
        audioDirectory: audioDirectory
      )
    } catch let failure as VoiceSessionHistoryError {
      throw failure
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not open its local storage."
      )
    }
  }

  public static func applicationSupportHistory() throws
    -> SQLiteVoiceSessionHistory
  {
    let root = try ApplicationIdentity.applicationSupportDirectory()
      .appending(path: "voice", directoryHint: .isDirectory)
    return try SQLiteVoiceSessionHistory(rootDirectory: root)
  }

  public func begin(sessionID: UUID, startedAt: Date) {
    let recorder = VoiceAudioArtifactRecorder(
      sessionID: sessionID,
      audioDirectory: audioDirectory
    )
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
    let recorder: VoiceAudioArtifactRecorder? = state.withLock { current in
      guard current?.sessionID == document.id else {
        return nil
      }
      defer { current = nil }
      return current?.recorder
    }
    let audioURL = try await recorder?.finishRetainingAudio()
    try await store.insert(document, audioURL: audioURL)
  }

  public func cancel(sessionID: UUID) async {
    let recorder: VoiceAudioArtifactRecorder? = state.withLock { current in
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
    try await store.recentSessions(limit: limit)
  }
}
