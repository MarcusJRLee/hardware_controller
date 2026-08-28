import AVFoundation

@testable import HardwareControllerMac

func makeVoiceAudioFixture() throws -> CapturedAudioBuffer {
  guard
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    ),
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: 1_600
    )
  else {
    throw MicrophoneCaptureError.invalidBuffer(
      "Could not create the sanitized audio fixture."
    )
  }
  buffer.frameLength = 1_600
  guard let channel = buffer.floatChannelData?[0] else {
    throw MicrophoneCaptureError.invalidBuffer(
      "Could not access the sanitized audio fixture."
    )
  }
  for frame in 0..<Int(buffer.frameLength) {
    channel[frame] = Float(sin(Double(frame) * 0.04)) * 0.05
  }
  return try CapturedAudioBuffer(copying: buffer)
}
