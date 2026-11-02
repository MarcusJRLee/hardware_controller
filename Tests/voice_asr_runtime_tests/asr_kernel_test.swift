import AVFoundation
import Foundation
import Testing

@testable import VoiceASRRuntime

struct ASRKernelTest {
  typealias Segment = ASRKernel.RuntimeSegment

  /// Contiguous segments become trimmed, space-joined text with their times.
  @Test
  func decodesContiguousSegments() throws {
    let text = Data(" send it now".utf8)
    let transcript = try ASRKernel.decode(
      transcript: text[...],
      runtimeSegments: [
        Segment(startMilliseconds: 0, endMilliseconds: 400, textOffset: 0, textLength: 8),
        Segment(startMilliseconds: 400, endMilliseconds: 900, textOffset: 8, textLength: 4),
      ]
    )
    #expect(transcript.text == "send it now")
    #expect(transcript.segments.map(\.endMilliseconds) == [400, 900])
  }

  /// Gaps, overlaps, reversed times, and unclaimed text are runtime faults.
  @Test(arguments: [
    [Segment(startMilliseconds: 0, endMilliseconds: 1, textOffset: 1, textLength: 3)],
    [Segment(startMilliseconds: 0, endMilliseconds: 1, textOffset: 0, textLength: 2)],
    [Segment(startMilliseconds: 5, endMilliseconds: 1, textOffset: 0, textLength: 4)],
    [Segment(startMilliseconds: 0, endMilliseconds: 1, textOffset: 0, textLength: 9)],
  ])
  func rejectsInconsistentSegments(segments: [Segment]) {
    #expect(throws: ASRKernelError.self) {
      try ASRKernel.decode(transcript: Data("send".utf8)[...], runtimeSegments: segments)
    }
  }

  @Test
  func mapsLanguageTags() {
    #expect(ASRKernelRequest.runtimeLanguage(for: ["en-US"]) == "en")
    #expect(ASRKernelRequest.runtimeLanguage(for: ["en-US", "fr-FR"]) == "auto")
    #expect(ASRKernelRequest.runtimeLanguage(for: ["1234"]) == "auto")
  }

  /// The real runtime transcribes the pinned clip. A CPU decode saturates the
  /// runner and starves timing-sensitive tests in the same process, so
  /// `scripts/check.sh` runs it alone with `HC_RUN_ASR_KERNEL=1`.
  @Test(
    .enabled(
      if: Assets.available && ProcessInfo.processInfo.environment["HC_RUN_ASR_KERNEL"] == "1")
  )
  func transcribesRealSpeech() throws {
    let kernel = try ASRKernel(
      modelURL: Assets.directory.appending(path: "whisper-tiny.en-Q8_0.gguf"),
      speechDetectionURL: Assets.directory.appending(path: "silero-vad-v6.2-F32.gguf"),
      useGPU: false,
      threadCount: 2
    )
    #expect(kernel.capabilities.supportsSpeechDetection)
    let transcript = try kernel.transcribe(
      try Assets.samples("jfk.wav"),
      request: ASRKernelRequest(language: "en", vocabulary: [], detectSpeech: true)
    )
    #expect(transcript.text.lowercased().contains("ask not what your country can do for you"))
    #expect(throws: ASRKernelError.noSpeechDetected) {
      try kernel.transcribe(
        [Float](repeating: 0, count: 32_000),
        request: ASRKernelRequest(language: "en", vocabulary: [], detectSpeech: true)
      )
    }
  }
}

private enum Assets {
  static let directory = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: ".build/asr_test_assets")

  static var available: Bool {
    FileManager.default.fileExists(atPath: directory.appending(path: "jfk.wav").path)
  }

  static func samples(_ name: String) throws -> [Float] {
    let file = try AVAudioFile(
      forReading: directory.appending(path: name),
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    let buffer = try #require(
      AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    )
    try file.read(into: buffer)
    #expect(file.processingFormat.sampleRate == 16_000)
    let channel = try #require(buffer.floatChannelData?[0])
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  }
}
