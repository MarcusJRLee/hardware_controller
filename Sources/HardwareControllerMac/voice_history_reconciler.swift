@preconcurrency import AVFoundation
import Foundation
import HardwareControllerCore

/// Reconciles app-owned audio crash states once before History maintenance.
actor VoiceHistoryReconciler {
  private let store: SQLiteVoiceSessionStore
  private let audioDirectory: URL
  private var didReconcile = false

  init(
    store: SQLiteVoiceSessionStore,
    audioDirectory: URL
  ) {
    self.store = store
    self.audioDirectory = audioDirectory
  }

  func reconcileIfNeeded() async throws -> VoiceHistoryRecoveryReport? {
    guard !didReconcile else {
      return nil
    }
    let completedAt = Date()
    let descriptors = try await store.recoveryDescriptors()
    let artifacts = try artifactDescriptors()
    let plan = VoiceHistoryRecoveryPlanner.plan(
      sessions: descriptors.map {
        VoiceHistoryRecoverySessionDescriptor(
          id: $0.id,
          audioFilename: $0.audioFilename,
          audioExpirationReason: $0.audioExpirationReason
        )
      },
      artifacts: artifacts,
      now: completedAt
    )
    var completedActions: [VoiceHistoryRecoveryAction] = []
    var issues = plan.issues.map { issue in
      switch issue {
      case .unreadableArtifact(let filename):
        VoiceHistoryRecoveryRuntimeIssue.unreadableArtifact(
          filename: filename
        )
      }
    }

    for action in plan.actions {
      do {
        try await perform(action, recoveredAt: completedAt)
        completedActions.append(action)
      } catch {
        issues.append(
          .actionFailed(filename: action.filename)
        )
      }
    }
    if await store.consumeInvalidSessionRecordCount() > 0 {
      issues.append(.invalidSessionRecord)
    }
    didReconcile = true
    return VoiceHistoryRecoveryReport(
      completedAt: completedAt,
      completedActions: completedActions,
      issues: issues
    )
  }

  private func artifactDescriptors() throws
    -> [VoiceHistoryRecoveryArtifactDescriptor]
  {
    let keys: Set<URLResourceKey> = [
      .contentModificationDateKey,
      .isRegularFileKey,
    ]
    let contents = try FileManager.default.contentsOfDirectory(
      at: audioDirectory,
      includingPropertiesForKeys: Array(keys),
      options: []
    )
    return contents.compactMap { url in
      guard
        let values = try? url.resourceValues(forKeys: keys),
        values.isRegularFile == true
      else {
        return nil
      }
      return VoiceHistoryRecoveryArtifactDescriptor(
        filename: url.lastPathComponent,
        modifiedAt: values.contentModificationDate ?? .distantPast,
        isReadableAudio: (try? Self.validateAudio(at: url)) != nil
      )
    }
  }

  private func perform(
    _ action: VoiceHistoryRecoveryAction,
    recoveredAt: Date
  ) async throws {
    switch action {
    case .discardCommittedQuarantine(let filename),
      .removeStaleUnreadable(let filename):
      let url = audioDirectory.appending(path: filename)
      guard FileManager.default.fileExists(atPath: url.path) else {
        return
      }
      try FileManager.default.removeItem(at: url)

    case .restoreQuarantine(
      let filename,
      let destinationFilename,
      _
    ):
      let source = audioDirectory.appending(path: filename)
      let destination = audioDirectory.appending(
        path: destinationFilename
      )
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw VoiceSessionHistoryError.audioUnavailable(
          "Voice History found conflicting recovery audio."
        )
      }
      try FileManager.default.moveItem(at: source, to: destination)

    case .recover(let filename, let preferredSessionID, let kind):
      let source = audioDirectory.appending(path: filename)
      let values = try source.resourceValues(
        forKeys: [.contentModificationDateKey]
      )
      let sessionID = preferredSessionID ?? UUID()
      let destination = audioDirectory.appending(
        path: "\(sessionID.uuidString).caf"
      )
      if source != destination {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
          throw VoiceSessionHistoryError.audioUnavailable(
            "Voice History found conflicting recovery audio."
          )
        }
        try FileManager.default.moveItem(at: source, to: destination)
      }
      do {
        try await store.insertRecoveredSession(
          id: sessionID,
          audioURL: destination,
          kind: kind,
          recoveredAt: recoveredAt,
          artifactModifiedAt: values.contentModificationDate ?? recoveredAt
        )
      } catch {
        // Keep the finalized orphan so a later process can retry reconciliation.
        throw error
      }
    }
  }

  private static func validateAudio(at url: URL) throws {
    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat.sampleRate > 0, file.length > 0 else {
      throw VoiceSessionHistoryError.audioUnavailable(
        "Voice History found unreadable recovery audio."
      )
    }
  }
}

extension VoiceHistoryRecoveryAction {
  fileprivate var filename: String {
    switch self {
    case .discardCommittedQuarantine(let filename),
      .restoreQuarantine(let filename, _, _),
      .recover(let filename, _, _),
      .removeStaleUnreadable(let filename):
      filename
    }
  }
}
