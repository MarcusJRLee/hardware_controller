@preconcurrency import AVFoundation
import Foundation
import HardwareControllerASRProtocol

/// Converts captured audio of any PCM format to 16 kHz mono float samples.
///
/// One converter carries resampler state across buffers, so a recording is
/// converted as one continuous stream rather than independent pieces.
struct ASRSampleAccumulator {
  private(set) var samples: [Float] = []
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private let outputFormat: AVAudioFormat
  private let maximumSampleCount: Int

  private static let resamplerCarryFrames: AVAudioFrameCount = 4_096

  init(maximumSampleCount: Int = ASRAudioSamples.maximumSampleCount)
    throws(SpeechRecognitionBackendError)
  {
    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(ASRAudioSamples.sampleRate),
        channels: 1,
        interleaved: false
      )
    else {
      throw .conversionFailed("The speech audio format could not be created.")
    }
    self.outputFormat = outputFormat
    self.maximumSampleCount = maximumSampleCount
  }

  mutating func append(_ buffer: AVAudioPCMBuffer) throws(SpeechRecognitionBackendError) {
    guard buffer.frameLength > 0 else {
      return
    }
    if let inputFormat, inputFormat != buffer.format {
      // A route change switches formats; drain the old stream before the new one.
      try flush()
    }
    let converter = try converter(for: buffer.format)
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let capacity =
      AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
      + Self.resamplerCarryFrames
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      throw .conversionFailed("Speech audio could not be buffered.")
    }
    let input = OneShotConverterInput(buffer)
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      input.next(inputStatus)
    }
    guard status != .error, error == nil else {
      throw .conversionFailed("Speech audio could not be converted.")
    }
    try appendConverted(output)
  }

  private mutating func appendConverted(_ output: AVAudioPCMBuffer)
    throws(SpeechRecognitionBackendError)
  {
    let count = Int(output.frameLength)
    guard count > 0 else {
      return
    }
    guard let channel = output.floatChannelData?[0] else {
      throw .conversionFailed("Speech audio could not be converted.")
    }
    guard samples.count + count <= maximumSampleCount else {
      throw .recognitionFailed("The recording is longer than local transcription allows.")
    }
    // Zeroing keeps timing exact; dropping a sample would shift every segment.
    samples.append(
      contentsOf: UnsafeBufferPointer(start: channel, count: count).lazy.map {
        $0.isFinite ? $0 : 0
      }
    )
  }

  /// Drains the frames the resampler still holds; without this the last tens of
  /// milliseconds of every recording would be lost.
  mutating func flush() throws(SpeechRecognitionBackendError) {
    guard let converter else {
      return
    }
    guard
      let output = AVAudioPCMBuffer(
        pcmFormat: outputFormat, frameCapacity: Self.resamplerCarryFrames)
    else {
      throw .conversionFailed("Speech audio could not be buffered.")
    }
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      inputStatus.pointee = .endOfStream
      return nil
    }
    guard status != .error, error == nil else {
      throw .conversionFailed("Speech audio could not be converted.")
    }
    try appendConverted(output)
    // A drained converter accepts no more input; the next buffer starts fresh.
    self.converter = nil
    inputFormat = nil
  }

  /// Splits the samples into buffers another recognizer can consume.
  func pcmBuffers(framesPerBuffer: Int = 1_600) throws(SpeechRecognitionBackendError)
    -> [AVAudioPCMBuffer]
  {
    // A loop, not `map`: older SDKs' `map` is `rethrows`, which erases typed throws.
    var buffers: [AVAudioPCMBuffer] = []
    for start in stride(from: 0, to: samples.count, by: framesPerBuffer) {
      let count = min(framesPerBuffer, samples.count - start)
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: outputFormat,
          frameCapacity: AVAudioFrameCount(count)
        ),
        let channel = buffer.floatChannelData?[0]
      else {
        throw .conversionFailed("Fallback audio could not be buffered.")
      }
      buffer.frameLength = AVAudioFrameCount(count)
      samples.withUnsafeBufferPointer { source in
        guard let base = source.baseAddress else {
          return
        }
        channel.update(from: base + start, count: count)
      }
      buffers.append(buffer)
    }
    return buffers
  }

  private mutating func converter(
    for format: AVAudioFormat
  ) throws(SpeechRecognitionBackendError) -> AVAudioConverter {
    if let converter, let inputFormat, inputFormat == format {
      return converter
    }
    guard let created = AVAudioConverter(from: format, to: outputFormat) else {
      throw .conversionFailed("This microphone format cannot be converted for speech.")
    }
    converter = created
    inputFormat = format
    return created
  }
}

/// Hands one buffer to AVAudioConverter, then reports no data.
///
/// The Xcode 26 SDK declares the converter input block `@Sendable`, but the
/// converter calls it synchronously inside `convert(to:error:withInputFrom:)`,
/// so this state is never touched concurrently.
private final class OneShotConverterInput: @unchecked Sendable {
  private var buffer: AVAudioPCMBuffer?

  init(_ buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

  func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    guard let buffer else {
      status.pointee = .noDataNow
      return nil
    }
    self.buffer = nil
    status.pointee = .haveData
    return buffer
  }
}
