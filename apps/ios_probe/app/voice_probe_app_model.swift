import AVFAudio
import Combine
import Foundation
import VoiceProbeShared

@MainActor
final class VoiceProbeAppModel: ObservableObject {
  @Published private(set) var snapshot = VoiceProbeSnapshot.idle(sequence: 0)
  @Published private(set) var errorMessage: String?

  private let service: VoiceProbeCaptureService?
  private var refreshTask: Task<Void, Never>?

  init() {
    guard
      let documentsURL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
      ).first
    else {
      service = nil
      errorMessage = "The local app container is unavailable."
      return
    }
    service = VoiceProbeCaptureService(
      store: VoiceProbeKeychainStore(),
      captureURL: documentsURL.appendingPathComponent("voice_probe_capture.caf")
    )
  }

  var isRecording: Bool {
    snapshot.phase == .recording
  }

  func activate() {
    guard refreshTask == nil else {
      return
    }
    refreshTask = Task { [weak self] in
      guard let self else {
        return
      }
      while !Task.isCancelled {
        await processPendingCommand()
        await refresh()
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  func deactivate() {
    refreshTask?.cancel()
    refreshTask = nil
  }

  func start() {
    perform { service in
      try await service.start()
    }
  }

  func stop() {
    perform { service in
      try await service.stop()
    }
  }

  func handleInterruption(_ notification: Notification) {
    guard
      let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      AVAudioSession.InterruptionType(rawValue: rawValue) == .began
    else {
      return
    }
    guard let service else {
      return
    }
    Task {
      await service.interrupt()
      await refresh()
    }
  }

  private func processPendingCommand() async {
    guard let service else {
      return
    }
    do {
      try await service.processPendingCommand()
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func refresh() async {
    guard let service else {
      return
    }
    if let updatedSnapshot = try? await service.snapshot() {
      snapshot = updatedSnapshot
    }
  }

  private func perform(
    _ operation: @escaping @Sendable (VoiceProbeCaptureService) async throws -> Void
  ) {
    guard let service else {
      return
    }
    errorMessage = nil
    Task {
      do {
        try await operation(service)
        await refresh()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
