import AVFAudio
import Combine
import Foundation

@MainActor
protocol VoiceInputHistoryAudioPlaying: AnyObject {
  var completionHandler: (@MainActor @Sendable () -> Void)? { get set }

  func play(url: URL) throws
  func stop()
}

@MainActor
final class VoiceInputHistoryAudioPlayer: NSObject, AVAudioPlayerDelegate,
  VoiceInputHistoryAudioPlaying
{
  var completionHandler: (@MainActor @Sendable () -> Void)?
  private var player: AVAudioPlayer?

  func play(url: URL) throws {
    let player = try AVAudioPlayer(contentsOf: url)
    player.delegate = self
    player.prepareToPlay()
    guard player.play() else {
      throw VoiceInputHistoryError.storageUnavailable
    }
    self.player = player
  }

  func stop() {
    player?.stop()
    player = nil
  }

  nonisolated func audioPlayerDidFinishPlaying(
    _ player: AVAudioPlayer,
    successfully flag: Bool
  ) {
    let finishedPlayerID = ObjectIdentifier(player)
    Task { @MainActor [weak self] in
      guard
        let self,
        let currentPlayer = self.player,
        ObjectIdentifier(currentPlayer) == finishedPlayerID
      else {
        return
      }
      self.player = nil
      self.completionHandler?()
    }
  }
}

@MainActor
final class VoiceInputHistoryAudioPlayerModel: ObservableObject {
  @Published private(set) var playingSessionID: UUID?
  @Published private(set) var errorMessage: String?

  private let player: any VoiceInputHistoryAudioPlaying

  init(player: any VoiceInputHistoryAudioPlaying = VoiceInputHistoryAudioPlayer()) {
    self.player = player
    player.completionHandler = { [weak self] in
      self?.playingSessionID = nil
    }
  }

  func toggle(_ session: VoiceInputHistorySession) {
    if playingSessionID == session.id {
      player.stop()
      playingSessionID = nil
      errorMessage = nil
      return
    }
    guard let artifact = session.audioArtifact else {
      errorMessage = "This recording expired; its transcript remains available."
      return
    }
    do {
      if playingSessionID != nil {
        player.stop()
      }
      try player.play(url: artifact.url)
      playingSessionID = session.id
      errorMessage = nil
    } catch {
      playingSessionID = nil
      errorMessage = "This local recording could not be played."
    }
  }

  func stop() {
    player.stop()
    playingSessionID = nil
  }
}
