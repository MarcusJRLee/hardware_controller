import AVFAudio
import ActivityKit
import AudioToolbox
import Foundation
import VoiceProbeShared

enum VoiceProbeCaptureError: Error, LocalizedError, Sendable {
  case alreadyRecording
  case microphoneDenied
  case recordingFailed

  var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      "A recording is already active."
    case .microphoneDenied:
      "Microphone access is required. Enable it in Settings."
    case .recordingFailed:
      "The local recorder could not start."
    }
  }
}

actor VoiceProbeCaptureService {
  private let store: any VoiceProbeStateStoring
  private let captureURL: URL
  private var recorder: AVAudioRecorder?
  private var activityID: String?
  private var heartbeatTask: Task<Void, Never>?
  private var sessionID: UUID?
  private var sequence: UInt64

  init(store: any VoiceProbeStateStoring, captureURL: URL) {
    self.store = store
    self.captureURL = captureURL
    sequence = (try? store.readSnapshot().sequence) ?? 0
  }

  func snapshot() throws -> VoiceProbeSnapshot {
    try store.readSnapshot()
  }

  func start(sessionID requestedSessionID: UUID = UUID()) async throws {
    guard recorder == nil else {
      throw VoiceProbeCaptureError.alreadyRecording
    }
    do {
      guard await AVAudioApplication.requestRecordPermission() else {
        throw VoiceProbeCaptureError.microphoneDenied
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
        throw VoiceProbeCaptureError.recordingFailed
      }

      recorder = newRecorder
      sessionID = requestedSessionID
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
        VoiceProbeSnapshot(
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
    guard let recorder, let sessionID else {
      return
    }
    heartbeatTask?.cancel()
    heartbeatTask = nil
    recorder.stop()
    self.recorder = nil

    do {
      try writeSnapshot(
        VoiceProbeSnapshot(
          phase: .transcribing,
          sessionID: sessionID,
          sequence: nextSequence(),
          heartbeatAt: nil,
          text: nil
        )
      )

      let byteCount =
        ((try? FileManager.default.attributesOfItem(atPath: captureURL.path)[.size])
        as? NSNumber)?.uint64Value ?? 0
      let result =
        "K0 local capture completed (\(byteCount) audio bytes). "
        + "This probe validates keyboard handoff; local transcription follows in the iOS implementation."
      try writeSnapshot(
        .ready(
          sessionID: sessionID,
          sequence: nextSequence(),
          text: result
        )
      )
      await relinquishCapture(endingPhase: .ready)
    } catch {
      try? writeSnapshot(
        VoiceProbeSnapshot(
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
      VoiceProbeSnapshot(
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
    guard VoiceProbeCommandPolicy().accepts(command, now: .now) else {
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
    let attributes = VoiceProbeActivityAttributes(sessionID: sessionID)
    let content = ActivityContent(
      state: VoiceProbeActivityAttributes.ContentState(phase: .recording),
      staleDate: Date.now.addingTimeInterval(3)
    )
    activityID = try? Activity.request(
      attributes: attributes,
      content: content,
      pushType: nil
    ).id
  }

  private func endLiveActivity(phase: VoiceProbeSnapshot.Phase) async {
    let endingActivityID = activityID
    activityID = nil
    await Self.endLiveActivity(id: endingActivityID, phase: phase)
  }

  private func updateLiveActivity(phase: VoiceProbeSnapshot.Phase) async {
    let updatingActivityID = activityID
    await Self.updateLiveActivity(id: updatingActivityID, phase: phase)
  }

  private func relinquishCapture(endingPhase: VoiceProbeSnapshot.Phase) async {
    heartbeatTask?.cancel()
    heartbeatTask = nil
    recorder?.stop()
    recorder = nil
    await endLiveActivity(phase: endingPhase)
    sessionID = nil
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private nonisolated static func endLiveActivity(
    id: String?,
    phase: VoiceProbeSnapshot.Phase
  ) async {
    let content = ActivityContent(
      state: VoiceProbeActivityAttributes.ContentState(phase: phase),
      staleDate: nil
    )
    let matchingActivity = Activity<VoiceProbeActivityAttributes>.activities.first {
      $0.id == id
    }
    await matchingActivity?.end(content, dismissalPolicy: .immediate)
  }

  private nonisolated static func updateLiveActivity(
    id: String?,
    phase: VoiceProbeSnapshot.Phase
  ) async {
    guard let id else {
      return
    }
    let content = ActivityContent(
      state: VoiceProbeActivityAttributes.ContentState(phase: phase),
      staleDate: Date.now.addingTimeInterval(3)
    )
    let matchingActivity = Activity<VoiceProbeActivityAttributes>.activities.first {
      $0.id == id
    }
    await matchingActivity?.update(content)
  }

  private func nextSequence() -> UInt64 {
    sequence &+= 1
    return sequence
  }

  private func writeSnapshot(_ snapshot: VoiceProbeSnapshot) throws {
    try store.writeSnapshot(snapshot)
  }
}
