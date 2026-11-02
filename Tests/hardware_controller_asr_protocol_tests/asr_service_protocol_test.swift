import Foundation
import HardwareControllerASRProtocol
import Testing

struct ASRServiceProtocolTest {
  /// Samples survive the boundary bit for bit.
  @Test
  func samplesRoundTrip() throws {
    let samples: [Float] = [0, 1, -1, 0.5, -0.25, .leastNonzeroMagnitude]
    #expect(try ASRAudioSamples.decode(ASRAudioSamples.encode(samples)) == samples)
  }

  /// Empty, ragged, oversized, and non-finite audio is rejected, never trimmed.
  @Test(arguments: [
    Data(),
    Data([0, 0, 0]),
    ASRAudioSamples.encode([.nan]),
    ASRAudioSamples.encode([1, .infinity]),
  ])
  func invalidAudioIsRejected(data: Data) {
    #expect(throws: ASRServiceFailure.invalidAudio) { try ASRAudioSamples.decode(data) }
  }

  @Test
  func audioOverTheLimitIsRejected() {
    let data = Data(count: (ASRAudioSamples.maximumSampleCount + 1) * 4)
    #expect(throws: ASRServiceFailure.invalidAudio) { try ASRAudioSamples.decode(data) }
  }

  /// Replies keep their typed failure across encoding.
  @Test
  func repliesRoundTrip() throws {
    let transcript = ASRServiceTranscript(
      text: "send it",
      segments: [ASRServiceSegment(startMilliseconds: 0, endMilliseconds: 900, text: "send it")]
    )
    for reply in [ASRServiceReply.success(transcript), .failure(.noSpeechDetected)] {
      let decoded = try ASRServiceCodec.decode(
        ASRServiceReply<ASRServiceTranscript>.self,
        from: ASRServiceCodec.encode(reply)
      )
      #expect(decoded == reply)
    }
  }

  @Test
  func malformedMessagesAreTyped() {
    #expect(throws: ASRServiceFailure.invalidMessage) {
      try ASRServiceCodec.decode(ASRLoadRequest.self, from: Data("{".utf8))
    }
  }
}
