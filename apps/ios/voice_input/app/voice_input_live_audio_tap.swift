import AVFAudio
import Foundation

/// Delivers microphone audio as 16 kHz mono samples while a recording runs.
///
/// The tap only feeds live decoding. The file recorder remains the durable
/// capture, so a tap that fails or stops early never loses audio.
protocol VoiceInputLiveAudioTapping: Sendable {
  func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws
  func stop()
}

enum VoiceInputLiveAudioTapError: Error, Equatable, Sendable {
  case unsupportedInputFormat
}

/// Converts arbitrary PCM input to the 16 kHz mono float samples ASR expects.
///
/// AVAudioEngine calls one tap block serially, so a converter owned by that
/// block is never used concurrently.
final class VoiceInputSampleConverter: @unchecked Sendable {
  static let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )

  private static let resamplerCarryFrames: AVAudioFrameCount = 4_096

  private let converter: AVAudioConverter
  private let inputFormat: AVAudioFormat

  init(inputFormat: AVAudioFormat) throws {
    guard
      inputFormat.sampleRate > 0,
      inputFormat.channelCount > 0,
      let outputFormat = Self.outputFormat,
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else {
      throw VoiceInputLiveAudioTapError.unsupportedInputFormat
    }
    self.converter = converter
    self.inputFormat = inputFormat
  }

  /// Returns the converted samples, or an empty array when nothing is ready.
  func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
    guard
      buffer.format == inputFormat,
      buffer.frameLength > 0,
      let outputFormat = Self.outputFormat
    else {
      return []
    }
    // The resampler may release frames it held back from the previous call, so
    // capacity must exceed this buffer's share or those frames would be lost.
    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let capacity =
      AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
      + Self.resamplerCarryFrames
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
    else {
      return []
    }
    var delivered = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      guard !delivered else {
        inputStatus.pointee = .noDataNow
        return nil
      }
      delivered = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard
      status != .error,
      error == nil,
      let channel = output.floatChannelData?[0]
    else {
      return []
    }
    // Zeroing keeps sample timing exact; dropping would shift every timestamp.
    return UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
      .map { $0.isFinite ? $0 : 0 }
  }
}

/// The actor-owned capture service starts and stops this tap; AVAudioEngine
/// never crosses an isolation boundary, and the tap block only converts and
/// forwards samples.
final class VoiceInputSystemLiveAudioTap: VoiceInputLiveAudioTapping, @unchecked Sendable {
  private let engine = AVAudioEngine()

  func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    let converter = try VoiceInputSampleConverter(inputFormat: format)
    input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
      let samples = converter.convert(buffer)
      if !samples.isEmpty {
        onSamples(samples)
      }
    }
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw error
    }
  }

  func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }
}
