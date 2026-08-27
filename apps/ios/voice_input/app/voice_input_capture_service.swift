import AVFAudio
import ActivityKit
import AudioToolbox
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

actor VoiceInputCaptureService {
  private let store: any VoiceInputStateStoring
  private let captureURL: URL
  private let asrWorkflow: VoiceInputASRWorkflow?
  private let sessionFinalizer: VoiceInputSessionFinalizer?
  private var recorder: AVAudioRecorder?
  private var activityID: String?
  private var heartbeatTask: Task<Void, Never>?
  private var sessionID: UUID?
  private var sessionStartedAt: Date?
  private var sequence: UInt64

  init(
    store: any VoiceInputStateStoring,
    captureURL: URL,
    asrWorkflow: VoiceInputASRWorkflow? = nil,
    sessionFinalizer: VoiceInputSessionFinalizer? = nil
  ) {
    self.store = store
    self.captureURL = captureURL
    self.asrWorkflow = asrWorkflow
    self.sessionFinalizer = sessionFinalizer
    sequence = (try? store.readSnapshot().sequence) ?? 0
  }

  func snapshot() throws -> VoiceInputSnapshot {
    try store.readSnapshot()
  }

  func start(sessionID requestedSessionID: UUID = UUID()) async throws {
    guard recorder == nil, sessionID == nil else {
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
      guard await AVAudioApplication.requestRecordPermission() else {
        throw VoiceInputCaptureError.microphoneDenied
      }
      guard sessionID == requestedSessionID, recorder == nil else {
        throw VoiceInputCaptureError.recordingFailed
      }

      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.record, mode: .measurement)
      try audioSession.setActive(true)

      let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ]
      let newRecorder = try AVAudioRecorder(url: captureURL, settings: settings)
      newRecorder.prepareToRecord()
      guard newRecorder.record() else {
        throw VoiceInputCaptureError.recordingFailed
      }

      recorder = newRecorder
      sessionStartedAt = .now
      try writeSnapshot(
        .recording(
          sessionID: requestedSessionID,
          sequence: nextSequence(),
          heartbeatAt: .now
        )
      )
      startLiveActivity(sessionID: requestedSessionID)
      startHeartbeat()
    } catch {
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
      throw error
    }
  }

  func stop() async throws {
    guard
      let recorder,
      let sessionID,
      let sessionStartedAt
    else {
      return
    }
    heartbeatTask?.cancel()
    heartbeatTask = nil
    recorder.stop()
    self.recorder = nil
    let sessionEndedAt = Date.now

    do {
      try writeSnapshot(
        VoiceInputSnapshot(
          phase: .transcribing,
          sessionID: sessionID,
          sequence: nextSequence(),
          heartbeatAt: nil,
          text: nil
        )
      )

      guard let asrWorkflow else {
        throw VoiceInputCaptureError.localModelUnavailable
      }
      guard let sessionFinalizer else {
        throw VoiceInputCaptureError.localHistoryUnavailable
      }
      let rawTranscript = try await asrWorkflow.transcribe(audioURL: captureURL)
      guard self.sessionID == sessionID else {
        return
      }
      let processed = try await sessionFinalizer.finalize(
        sessionID: sessionID,
        startedAt: sessionStartedAt,
        endedAt: sessionEndedAt,
        rawTranscript: rawTranscript,
        sourceAudioURL: captureURL
      )
      guard self.sessionID == sessionID else {
        return
      }
      try writeSnapshot(
        .ready(
          sessionID: sessionID,
          sequence: nextSequence(),
          text: processed.formattedText
        )
      )
      await relinquishCapture(endingPhase: .ready)
    } catch {
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
      throw error
    }
  }

  func interrupt() async {
    guard let sessionID else {
      return
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
  }

  func processPendingCommand() async throws {
    guard let command = try store.consumeCommand() else {
      return
    }
    guard VoiceInputCommandPolicy().accepts(command, now: .now) else {
      return
    }
    switch command.kind {
    case .start:
      if recorder == nil {
        try await start(sessionID: command.sessionID)
      }
    case .stop:
      if command.sessionID == sessionID {
        try await stop()
      }
    }
  }

  private func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, let self else {
          return
        }
        await self.heartbeat()
      }
    }
  }

  private func heartbeat() async {
    guard let sessionID, recorder != nil else {
      return
    }
    try? writeSnapshot(
      .recording(
        sessionID: sessionID,
        sequence: nextSequence(),
        heartbeatAt: .now
      )
    )
    await updateLiveActivity(phase: .recording)
    try? await processPendingCommand()
  }

  private func startLiveActivity(sessionID: UUID) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      return
    }
    let attributes = VoiceInputActivityAttributes(sessionID: sessionID)
    let content = ActivityContent(
      state: VoiceInputActivityAttributes.ContentState(phase: .recording),
      staleDate: Date.now.addingTimeInterval(3)
    )
    activityID = try? Activity.request(
      attributes: attributes,
      content: content,
      pushType: nil
    ).id
  }

  private func endLiveActivity(phase: VoiceInputSnapshot.Phase) async {
    let endingActivityID = activityID
    activityID = nil
    await Self.endLiveActivity(id: endingActivityID, phase: phase)
  }

  private func updateLiveActivity(phase: VoiceInputSnapshot.Phase) async {
    let updatingActivityID = activityID
    await Self.updateLiveActivity(id: updatingActivityID, phase: phase)
  }

  private func relinquishCapture(endingPhase: VoiceInputSnapshot.Phase) async {
    heartbeatTask?.cancel()
    heartbeatTask = nil
    recorder?.stop()
    recorder = nil
    await endLiveActivity(phase: endingPhase)
    sessionID = nil
    sessionStartedAt = nil
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private nonisolated static func endLiveActivity(
    id: String?,
    phase: VoiceInputSnapshot.Phase
  ) async {
    let content = ActivityContent(
      state: VoiceInputActivityAttributes.ContentState(phase: phase),
      staleDate: nil
    )
    let matchingActivity = Activity<VoiceInputActivityAttributes>.activities.first {
      $0.id == id
    }
    await matchingActivity?.end(content, dismissalPolicy: .immediate)
  }

  private nonisolated static func updateLiveActivity(
    id: String?,
    phase: VoiceInputSnapshot.Phase
  ) async {
    guard let id else {
      return
    }
    let content = ActivityContent(
      state: VoiceInputActivityAttributes.ContentState(phase: phase),
      staleDate: Date.now.addingTimeInterval(3)
    )
    let matchingActivity = Activity<VoiceInputActivityAttributes>.activities.first {
      $0.id == id
    }
    await matchingActivity?.update(content)
  }

  private func nextSequence() -> UInt64 {
    sequence &+= 1
    return sequence
  }

  private func writeSnapshot(_ snapshot: VoiceInputSnapshot) throws {
    try store.writeSnapshot(snapshot)
  }
}
