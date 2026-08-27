import AVFAudio
import ActivityKit
import AudioToolbox
import Foundation
import UIKit
import VoiceInputShared

protocol VoiceInputAudioRecording: Sendable {
  func prepareToRecord()
  func record() -> Bool
  func stop()
}

protocol VoiceInputAudioRecorderCreating: Sendable {
  func makeRecorder(at url: URL) throws -> any VoiceInputAudioRecording
}

protocol VoiceInputAudioSessionControlling: Sendable {
  func activateForRecording() throws
  func deactivateAfterRecording() throws
}

protocol VoiceInputLiveActivityManaging: Sendable {
  func start(sessionID: UUID, at date: Date) async -> String?
  func update(
    id: String?,
    phase: VoiceInputSnapshot.Phase,
    at date: Date
  ) async
  func end(
    id: String?,
    phase: VoiceInputSnapshot.Phase,
    at date: Date
  ) async
}

struct VoiceInputBackgroundTaskToken: Hashable, Sendable {
  fileprivate let id: UUID

  init() {
    id = UUID()
  }
}

protocol VoiceInputBackgroundTaskManaging: Sendable {
  func begin(
    name: String,
    expiration: @escaping @Sendable () async -> Void
  ) async -> VoiceInputBackgroundTaskToken?
  func end(_ token: VoiceInputBackgroundTaskToken?) async
}

struct VoiceInputSystemAudioSession: VoiceInputAudioSessionControlling {
  func activateForRecording() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement)
    try session.setActive(true)
  }

  func deactivateAfterRecording() throws {
    try AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }
}

struct VoiceInputSystemAudioRecorderFactory: VoiceInputAudioRecorderCreating {
  func makeRecorder(at url: URL) throws -> any VoiceInputAudioRecording {
    try VoiceInputSystemAudioRecorder(
      recorder: AVAudioRecorder(
        url: url,
        settings: [
          AVFormatIDKey: Int(kAudioFormatLinearPCM),
          AVSampleRateKey: 16_000,
          AVNumberOfChannelsKey: 1,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
        ]
      )
    )
  }
}

/// The actor-owned wrapper never exposes AVAudioRecorder across isolation boundaries.
private final class VoiceInputSystemAudioRecorder: VoiceInputAudioRecording,
  @unchecked Sendable
{
  private let recorder: AVAudioRecorder

  init(recorder: AVAudioRecorder) {
    self.recorder = recorder
  }

  func prepareToRecord() {
    recorder.prepareToRecord()
  }

  func record() -> Bool {
    recorder.record()
  }

  func stop() {
    recorder.stop()
  }
}

struct VoiceInputSystemLiveActivityManager: VoiceInputLiveActivityManaging {
  func start(sessionID: UUID, at date: Date) -> String? {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      return nil
    }
    let attributes = VoiceInputActivityAttributes(sessionID: sessionID)
    let content = ActivityContent(
      state: VoiceInputActivityAttributes.ContentState(phase: .recording),
      staleDate: date.addingTimeInterval(3)
    )
    return try? Activity.request(
      attributes: attributes,
      content: content,
      pushType: nil
    ).id
  }

  func update(
    id: String?,
    phase: VoiceInputSnapshot.Phase,
    at date: Date
  ) async {
    guard let id else {
      return
    }
    let content = ActivityContent(
      state: VoiceInputActivityAttributes.ContentState(phase: phase),
      staleDate: date.addingTimeInterval(3)
    )
    let matchingActivity = Activity<VoiceInputActivityAttributes>.activities.first {
      $0.id == id
    }
    await matchingActivity?.update(content)
  }

  func end(
    id: String?,
    phase: VoiceInputSnapshot.Phase,
    at _: Date
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
}

actor VoiceInputSystemBackgroundTaskManager: VoiceInputBackgroundTaskManaging {
  private var identifiers: [VoiceInputBackgroundTaskToken: UIBackgroundTaskIdentifier] = [:]

  func begin(
    name: String,
    expiration: @escaping @Sendable () async -> Void
  ) async -> VoiceInputBackgroundTaskToken? {
    let token = VoiceInputBackgroundTaskToken()
    let identifier = await MainActor.run {
      UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
        Task {
          await self?.expire(token, expiration: expiration)
        }
      }
    }
    guard identifier != .invalid else {
      return nil
    }
    identifiers[token] = identifier
    return token
  }

  func end(_ token: VoiceInputBackgroundTaskToken?) async {
    guard let token, let identifier = identifiers.removeValue(forKey: token) else {
      return
    }
    await MainActor.run {
      UIApplication.shared.endBackgroundTask(identifier)
    }
  }

  private func expire(
    _ token: VoiceInputBackgroundTaskToken,
    expiration: @escaping @Sendable () async -> Void
  ) async {
    await end(token)
    await expiration()
  }
}
