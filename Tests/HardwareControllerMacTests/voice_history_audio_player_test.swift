import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct VoiceHistoryAudioPlayerTest {
  @Test
  func playbackSpanIsClampedToTheImmutableArtifact() throws {
    let bounds = try VoiceHistoryPlaybackBounds.resolve(
      span: VoiceHistoryTimedSpan(
        startMilliseconds: -20,
        endMilliseconds: 1_200,
        text: "Timed words"
      ),
      audioDurationMilliseconds: 1_000
    )

    #expect(
      bounds
        == VoiceHistoryPlaybackBounds(
          startMilliseconds: 0,
          endMilliseconds: 1_000
        )
    )
  }

  @Test
  func playbackRejectsASpanOutsideTheArtifact() {
    #expect(throws: VoiceHistoryPlaybackError.invalidSpan) {
      try VoiceHistoryPlaybackBounds.resolve(
        span: VoiceHistoryTimedSpan(
          startMilliseconds: 1_100,
          endMilliseconds: 1_200,
          text: "Outside"
        ),
        audioDurationMilliseconds: 1_000
      )
    }
  }
}
