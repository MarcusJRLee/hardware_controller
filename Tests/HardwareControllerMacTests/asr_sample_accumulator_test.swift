import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct ASRSampleAccumulatorTest {
  /// Any capture format becomes 16 kHz mono, continuous across buffers.
  @Test
  func convertsToSixteenKilohertzMono() throws {
    var accumulator = try ASRSampleAccumulator()
    for _ in 0..<10 {
      try accumulator.append(capturedAudio().makePCMBuffer())
    }
    try accumulator.flush()
    // One second at 48 kHz stereo is 16,000 mono samples once the resampler drains.
    #expect(abs(accumulator.samples.count - 16_000) <= 16)
    #expect(accumulator.samples.allSatisfy { $0.isFinite })
    let buffers = try accumulator.pcmBuffers(framesPerBuffer: 1_600)
    #expect(buffers.reduce(0) { $0 + Int($1.frameLength) } == accumulator.samples.count)
    #expect(buffers.allSatisfy { $0.format.sampleRate == 16_000 && $0.format.channelCount == 1 })
  }

  /// A route change mid-recording keeps every frame from both formats.
  @Test
  func routeChangeKeepsBothStreams() throws {
    var accumulator = try ASRSampleAccumulator()
    for _ in 0..<5 {
      try accumulator.append(capturedAudio().makePCMBuffer())
    }
    for _ in 0..<5 {
      try accumulator.append(
        capturedAudio(frames: 4_410, sampleRate: 44_100, channels: 1).makePCMBuffer())
    }
    try accumulator.flush()
    #expect(abs(accumulator.samples.count - 16_000) <= 32)
  }

  @Test
  func rejectsRecordingsOverTheLimit() throws {
    var accumulator = try ASRSampleAccumulator(maximumSampleCount: 1_000)
    #expect(throws: SpeechRecognitionBackendError.self) {
      try accumulator.append(capturedAudio().makePCMBuffer())
    }
  }
}
