import AVFAudio
import Foundation
import VoiceInputShared

enum VoiceInputCaptureError: Error, LocalizedError, Sendable {
  case alreadyRecording
  case microphoneDenied
  case localHistoryUnavailable
  case localModelUnavailable
  case recordingFailed

  var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      "A recording is already active."
    case .microphoneDenied:
      "Microphone access is required. Enable it in Settings."
    case .localHistoryUnavailable:
      "Local Voice History must be available before recording."
    case .localModelUnavailable:
      "Choose a compatible local speech-to-text model before recording."
    case .recordingFailed:
      "The local recorder could not start."
    }
  }
}

protocol VoiceInputCapturing: Sendable {
  func snapshot() async throws -> VoiceInputSnapshot
  func start(sessionID: UUID) async throws
  func stop(styleKind: VoiceInputStyleKind) async throws
  func interrupt(reason: VoiceInputCaptureInterruptionReason) async
  func handleLifecycleEvent(
    _ event: VoiceInputLifecycleEvent
  ) async -> VoiceInputLifecycleDecision
  func processPendingCommand() async throws
  func reconcileOnActivation() async throws
}

extension VoiceInputCapturing {
  func reconcileOnActivation() async throws {}
}

actor VoiceInputCaptureService: VoiceInputCapturing {
  private let store: any VoiceInputStateStoring
  private let captureDirectoryURL: URL
  private let asrWorkflow: VoiceInputASRWorkflow?
  private let sessionFinalizer: VoiceInputSessionFinalizer?
  private let recoveryStore: (any VoiceInputRecoveryStoring)?
  private let permissionRequester: @Sendable () async -> Bool
  private let audioSession: any VoiceInputAudioSessionControlling
  private let recorderFactory: any VoiceInputAudioRecorderCreating
  private let activityManager: any VoiceInputLiveActivityManaging
  private let backgroundTaskManager: any VoiceInputBackgroundTaskManaging
  private let controlReloader: @Sendable () -> Void
  private let lifecyclePolicy = VoiceInputLifecyclePolicy()
  private let heartbeatInterval: Duration
  private let now: @Sendable () -> Date
  private var recorder: (any VoiceInputAudioRecording)?
  private var activityID: String?
  private var heartbeatTask: Task<Void, Never>?
  private var heartbeatPhase: VoiceInputSnapshot.Phase?
  private var sessionID: UUID?
  private var sessionStartedAt: Date?
  private var activeCaptureURL: URL?
  private var isTearingDown = false
  private var lastControlRecordingState: Bool?
  private var sequence: UInt64

  init(
    store: any VoiceInputStateStoring,
    captureDirectoryURL: URL,
    asrWorkflow: VoiceInputASRWorkflow? = nil,
    sessionFinalizer: VoiceInputSessionFinalizer? = nil,
    recoveryStore: (any VoiceInputRecoveryStoring)? = nil,
    permissionRequester: @escaping @Sendable () async -> Bool = {
      await AVAudioApplication.requestRecordPermission()
    },
    audioSession: any VoiceInputAudioSessionControlling = VoiceInputSystemAudioSession(),
    recorderFactory: any VoiceInputAudioRecorderCreating =
      VoiceInputSystemAudioRecorderFactory(),
    activityManager: any VoiceInputLiveActivityManaging =
      VoiceInputSystemLiveActivityManager(),
    backgroundTaskManager: any VoiceInputBackgroundTaskManaging =
      VoiceInputSystemBackgroundTaskManager(),
    controlReloader: @escaping @Sendable () -> Void = {},
    heartbeatInterval: Duration = .milliseconds(500),
    now: @escaping @Sendable () -> Date = { .now }
  ) {
    self.store = store
    self.captureDirectoryURL = captureDirectoryURL
    self.asrWorkflow = asrWorkflow
    self.sessionFinalizer = sessionFinalizer
    self.recoveryStore = recoveryStore
    self.permissionRequester = permissionRequester
    self.audioSession = audioSession
    self.recorderFactory = recorderFactory
    self.activityManager = activityManager
    self.backgroundTaskManager = backgroundTaskManager
    self.controlReloader = controlReloader
    self.heartbeatInterval = heartbeatInterval
    self.now = now
    sequence = (try? store.readSnapshot().sequence) ?? 0
  }

  func snapshot() throws -> VoiceInputSnapshot {
    try store.readSnapshot()
  }

  func reconcileOnActivation() async throws {
    guard sessionID == nil, recorder == nil, !isTearingDown else {
      return
    }
    await activityManager.endOrphanedActivities(at: now())
    let snapshot = try store.readSnapshot()
    guard
      snapshot.schemaRevision == VoiceInputSnapshot.schemaRevision,
      let orphanedSessionID = snapshot.sessionID,
      snapshot.phase == .recording || snapshot.phase == .transcribing
    else {
      return
    }
    try writeSnapshot(
      VoiceInputSnapshot(
        phase: .interrupted,
        sessionID: orphanedSessionID,
        sequence: nextSequence(),
        heartbeatAt: nil,
        text: nil
      )
    )
  }

  func start(sessionID requestedSessionID: UUID = UUID()) async throws {
    guard recorder == nil, sessionID == nil, !isTearingDown else {
      throw VoiceInputCaptureError.alreadyRecording
    }
    sessionID = requestedSessionID
    do {
      guard let asrWorkflow else {
        throw VoiceInputCaptureError.localModelUnavailable
      }
      guard sessionFinalizer != nil else {
        throw VoiceInputCaptureError.localHistoryUnavailable
      }
      try await asrWorkflow.prewarmSelectedModel()
      guard sessionID == requestedSessionID, recorder == nil else {
        throw VoiceInputCaptureError.recordingFailed
      }
      guard await permissionRequester() else {
        throw VoiceInputCaptureError.microphoneDenied
      }
      guard sessionID == requestedSessionID, recorder == nil else {
        throw VoiceInputCaptureError.recordingFailed
      }

      try Self.prepareCaptureDirectory(captureDirectoryURL)
      let captureURL = captureDirectoryURL.appendingPathComponent(
        "\(requestedSessionID.uuidString.lowercased()).partial"
      )
      guard !FileManager.default.fileExists(atPath: captureURL.path) else {
        throw VoiceInputCaptureError.recordingFailed
      }
      activeCaptureURL = captureURL
      try audioSession.activateForRecording()
      let newRecorder = try recorderFactory.makeRecorder(at: captureURL)
      newRecorder.prepareToRecord()
      guard newRecorder.record() else {
        throw VoiceInputCaptureError.recordingFailed
      }

      recorder = newRecorder
      sessionStartedAt = now()
      try Self.protectCaptureFile(captureURL)
      let requestedActivityID = await activityManager.start(
        sessionID: requestedSessionID,
        at: now()
      )
      guard sessionID == requestedSessionID, recorder != nil else {
        await activityManager.end(
          id: requestedActivityID,
          phase: .interrupted,
          at: now()
        )
        throw VoiceInputCaptureError.recordingFailed
      }
      activityID = requestedActivityID
      try writeSnapshot(
        .recording(
          sessionID: requestedSessionID,
          sequence: nextSequence(),
          heartbeatAt: now()
        )
      )
      startHeartbeat(phase: .recording)
    } catch {
      if sessionID == requestedSessionID {
        if recorder != nil {
          _ = await preservePartial(reason: .finalizationFailure, endedAt: now())
        }
        try? writeSnapshot(
          VoiceInputSnapshot(
            phase: .failed,
            sessionID: requestedSessionID,
            sequence: nextSequence(),
            heartbeatAt: nil,
            text: nil
          )
        )
        await relinquishCapture(endingPhase: .failed)
      }
      throw error
    }
  }

  func stop(styleKind: VoiceInputStyleKind = .natural) async throws {
    guard
      let recorder,
      let sessionID,
      let sessionStartedAt,
      let activeCaptureURL
    else {
      return
    }
    recorder.stop()
    self.recorder = nil
    let sessionEndedAt = now()
    let backgroundTask = await backgroundTaskManager.begin(
      name: "Finish local voice recording"
    ) { [weak self] in
      await self?.interrupt(reason: .backgroundExecutionExpired)
    }

    do {
      try writeSnapshot(
        .transcribing(
          sessionID: sessionID,
          sequence: nextSequence(),
          heartbeatAt: now()
        )
      )
      startHeartbeat(phase: .transcribing)
      await activityManager.update(
        id: activityID,
        phase: .transcribing,
        at: now()
      )

      guard let asrWorkflow else {
        throw VoiceInputCaptureError.localModelUnavailable
      }
      guard let sessionFinalizer else {
        throw VoiceInputCaptureError.localHistoryUnavailable
      }
      let rawTranscript = try await asrWorkflow.transcribe(audioURL: activeCaptureURL)
      guard self.sessionID == sessionID else {
        await backgroundTaskManager.end(backgroundTask)
        return
      }
      let processed = try await sessionFinalizer.finalize(
        sessionID: sessionID,
        startedAt: sessionStartedAt,
        endedAt: sessionEndedAt,
        rawTranscript: rawTranscript,
        sourceAudioURL: activeCaptureURL,
        style: styleKind.domainStyle
      )
      guard self.sessionID == sessionID else {
        await backgroundTaskManager.end(backgroundTask)
        return
      }
      try writeSnapshot(
        .ready(
          sessionID: sessionID,
          sequence: nextSequence(),
          text: processed.formattedText
        )
      )
      if FileManager.default.fileExists(atPath: activeCaptureURL.path) {
        try FileManager.default.removeItem(at: activeCaptureURL)
      }
      await relinquishCapture(endingPhase: .ready)
      await backgroundTaskManager.end(backgroundTask)
    } catch {
      guard self.sessionID == sessionID else {
        await backgroundTaskManager.end(backgroundTask)
        return
      }
      _ = await preservePartial(
        reason: .finalizationFailure,
        endedAt: sessionEndedAt
      )
      try? writeSnapshot(
        VoiceInputSnapshot(
          phase: .failed,
          sessionID: sessionID,
          sequence: nextSequence(),
          heartbeatAt: nil,
          text: nil
        )
      )
      await relinquishCapture(endingPhase: .failed)
      await backgroundTaskManager.end(backgroundTask)
      throw error
    }
  }

  func interrupt(reason: VoiceInputCaptureInterruptionReason) async {
    _ = await applyInterruption(reason: reason)
  }

  private func applyInterruption(
    reason: VoiceInputCaptureInterruptionReason
  ) async -> Bool {
    guard let sessionID else {
      return false
    }
    heartbeatTask?.cancel()
    heartbeatTask = nil
    heartbeatPhase = nil
    recorder?.stop()
    recorder = nil
    let disposition = await preservePartial(reason: reason, endedAt: now())
    guard self.sessionID == sessionID else {
      return false
    }
    if case .alreadyFinalized(let formattedText) = disposition {
      try? writeSnapshot(
        .ready(
          sessionID: sessionID,
          sequence: nextSequence(),
          text: formattedText
        )
      )
      await relinquishCapture(endingPhase: .ready)
      return false
    }
    try? writeSnapshot(
      VoiceInputSnapshot(
        phase: .interrupted,
        sessionID: sessionID,
        sequence: nextSequence(),
        heartbeatAt: nil,
        text: nil
      )
    )
    await relinquishCapture(endingPhase: .interrupted)
    return true
  }

  func handleLifecycleEvent(
    _ event: VoiceInputLifecycleEvent
  ) async -> VoiceInputLifecycleDecision {
    let decision = lifecyclePolicy.decision(
      for: event,
      captureOwned: sessionID != nil,
      liveActivityOwned: activityID != nil
    )
    switch decision {
    case .ignore:
      break
    case .continueCapture:
      if recorder != nil {
        await activityManager.update(
          id: activityID,
          phase: .recording,
          at: now()
        )
      }
    case .interrupt(let reason):
      guard await applyInterruption(reason: reason) else {
        return .ignore
      }
    }
    return decision
  }

  func processPendingCommand() async throws {
    guard let command = try store.consumeCommand() else {
      return
    }
    guard VoiceInputCommandPolicy().accepts(command, now: now()) else {
      return
    }
    switch command.kind {
    case .start:
      if recorder == nil, sessionID == nil {
        try await start(sessionID: command.sessionID)
      }
    case .stop:
      if command.sessionID == sessionID,
        let styleKind = command.styleKind
      {
        try await stop(styleKind: styleKind)
      }
    }
  }

  private func startHeartbeat(phase: VoiceInputSnapshot.Phase) {
    heartbeatPhase = phase
    guard heartbeatTask == nil else {
      return
    }
    let interval = heartbeatInterval
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled, let self else {
          return
        }
        await self.heartbeat()
      }
    }
  }

  private func heartbeat() async {
    guard let sessionID, let heartbeatPhase else {
      return
    }
    let snapshot: VoiceInputSnapshot
    switch heartbeatPhase {
    case .recording:
      guard recorder != nil else {
        return
      }
      snapshot = .recording(
        sessionID: sessionID,
        sequence: nextSequence(),
        heartbeatAt: now()
      )
    case .transcribing:
      guard recorder == nil else {
        return
      }
      snapshot = .transcribing(
        sessionID: sessionID,
        sequence: nextSequence(),
        heartbeatAt: now()
      )
    case .idle, .ready, .interrupted, .failed:
      return
    }
    try? writeSnapshot(snapshot)
    await activityManager.update(
      id: activityID,
      phase: heartbeatPhase,
      at: now()
    )
    if heartbeatPhase == .recording, recorder != nil {
      try? await processPendingCommand()
    }
  }

  private func relinquishCapture(endingPhase: VoiceInputSnapshot.Phase) async {
    isTearingDown = true
    heartbeatTask?.cancel()
    heartbeatTask = nil
    heartbeatPhase = nil
    let endingRecorder = recorder
    recorder = nil
    let endingActivityID = activityID
    activityID = nil
    sessionID = nil
    sessionStartedAt = nil
    activeCaptureURL = nil
    endingRecorder?.stop()
    await activityManager.end(
      id: endingActivityID,
      phase: endingPhase,
      at: now()
    )
    try? audioSession.deactivateAfterRecording()
    isTearingDown = false
  }

  private func preservePartial(
    reason: VoiceInputCaptureInterruptionReason,
    endedAt: Date
  ) async -> VoiceInputRecoveryDisposition? {
    guard
      let recoveryStore,
      let sessionID,
      let sessionStartedAt,
      let activeCaptureURL,
      FileManager.default.fileExists(atPath: activeCaptureURL.path)
    else {
      return nil
    }
    return try? await recoveryStore.preserveRecovery(
      sessionID: sessionID,
      startedAt: sessionStartedAt,
      endedAt: endedAt,
      reason: reason,
      sourceAudioURL: activeCaptureURL
    )
  }

  private static func prepareCaptureDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
      ]
    )
  }

  private static func protectCaptureFile(_ url: URL) throws {
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: url.path
    )
    var ownedURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try ownedURL.setResourceValues(values)
  }

  private func nextSequence() -> UInt64 {
    sequence &+= 1
    return sequence
  }

  private func writeSnapshot(_ snapshot: VoiceInputSnapshot) throws {
    try store.writeSnapshot(snapshot)
    let isRecording = snapshot.phase == .recording
    if lastControlRecordingState != isRecording {
      lastControlRecordingState = isRecording
      controlReloader()
    }
  }
}
