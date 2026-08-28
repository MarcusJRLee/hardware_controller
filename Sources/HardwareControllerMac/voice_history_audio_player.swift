@preconcurrency import AVFoundation
import Foundation
import HardwareControllerCore

public enum VoiceHistoryPlaybackError: Error, Equatable, Sendable {
  case invalidSpan
  case audioUnavailable
}

@MainActor
public protocol VoiceHistoryAudioPlaying: AnyObject {
  var isPlaying: Bool { get }
  func play(
    audioURL: URL,
    span: VoiceHistoryTimedSpan
  ) throws
  func stop()
}

struct VoiceHistoryPlaybackBounds: Equatable, Sendable {
  let startMilliseconds: Int64
  let endMilliseconds: Int64

  static func resolve(
    span: VoiceHistoryTimedSpan,
    audioDurationMilliseconds: Int64
  ) throws -> Self {
    let start = max(0, span.startMilliseconds)
    let end = min(audioDurationMilliseconds, span.endMilliseconds)
    guard start < end else {
      throw VoiceHistoryPlaybackError.invalidSpan
    }
    return Self(startMilliseconds: start, endMilliseconds: end)
  }
}

/// Owns one bounded local playback operation on the presentation actor.
@MainActor
public final class VoiceHistoryAudioPlayer: VoiceHistoryAudioPlaying {
  public private(set) var isPlaying = false

  private var player: AVAudioPlayer?
  private var stopTask: Task<Void, Never>?
  private var generation: UInt64 = 0
  private let stateChanged: @MainActor @Sendable (Bool) -> Void

  public init(
    stateChanged: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
  ) {
    self.stateChanged = stateChanged
  }

  public func play(
    audioURL: URL,
    span: VoiceHistoryTimedSpan
  ) throws {
    stop()
    let player = try AVAudioPlayer(contentsOf: audioURL)
    let durationMilliseconds = Int64((player.duration * 1_000).rounded())
    let bounds = try VoiceHistoryPlaybackBounds.resolve(
      span: span,
      audioDurationMilliseconds: durationMilliseconds
    )
    player.currentTime = Double(bounds.startMilliseconds) / 1_000
    guard player.prepareToPlay(), player.play() else {
      throw VoiceHistoryPlaybackError.audioUnavailable
    }
    self.player = player
    isPlaying = true
    stateChanged(true)
    generation &+= 1
    let activeGeneration = generation
    stopTask = Task { [weak self] in
      try? await Task.sleep(
        for: .milliseconds(
          bounds.endMilliseconds - bounds.startMilliseconds
        )
      )
      guard
        !Task.isCancelled,
        let self,
        self.generation == activeGeneration
      else {
        return
      }
      self.stop()
    }
  }

  public func stop() {
    generation &+= 1
    stopTask?.cancel()
    stopTask = nil
    player?.stop()
    player = nil
    guard isPlaying else {
      return
    }
    isPlaying = false
    stateChanged(false)
  }
}
