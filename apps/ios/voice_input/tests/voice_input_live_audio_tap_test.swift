import AVFAudio
import XCTest

@testable import VoiceInput

final class VoiceInputSampleConverterTest: XCTestCase {
  func testStereoInputBecomesSixteenKilohertzMonoWithExactTiming() throws {
    let input = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
      )
    )
    let converter = try VoiceInputSampleConverter(inputFormat: input)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 48_000))
    buffer.frameLength = 48_000
    for channel in 0..<2 {
      let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
      for frame in 0..<48_000 {
        samples[frame] = sinf(Float(frame) * 2 * .pi * 440 / 48_000) * 0.5
      }
    }

    var converted: [Float] = []
    for _ in 0..<10 {
      converted += converter.convert(buffer)
    }

    // Only the resampler's fixed filter delay may be outstanding; frames held
    // back by one call must be released by the next instead of accumulating.
    XCTAssertLessThanOrEqual(converted.count, 160_000)
    XCTAssertGreaterThanOrEqual(converted.count, 160_000 - 1_024)
    XCTAssertTrue(converted.allSatisfy { $0.isFinite && abs($0) <= 1 })
    XCTAssertGreaterThan(converted.map(abs).max() ?? 0, 0.1)
  }

  func testMismatchedOrEmptyBuffersProduceNoSamples() throws {
    let mono = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 1,
        interleaved: false
      )
    )
    let other = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 8_000,
        channels: 1,
        interleaved: false
      )
    )
    let converter = try VoiceInputSampleConverter(inputFormat: mono)
    let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 16))
    let foreign = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: other, frameCapacity: 16))
    foreign.frameLength = 16

    XCTAssertEqual(converter.convert(empty), [])
    XCTAssertEqual(converter.convert(foreign), [])
  }
}
