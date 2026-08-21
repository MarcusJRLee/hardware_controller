import AVFoundation
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct SpeechRecognitionBackendTest {
  @Test
  func runtimeVersionSelectsTheCompatibleAppleBackend() {
    #expect(
      AppleSpeechRecognitionSessionFactory.backendKind(
        for: OperatingSystemVersion(
          majorVersion: 26,
          minorVersion: 0,
          patchVersion: 0
        )
      ) == .speechAnalyzer
    )
    #expect(
      AppleSpeechRecognitionSessionFactory.backendKind(
        for: OperatingSystemVersion(
          majorVersion: 15,
          minorVersion: 6,
          patchVersion: 0
        )
      ) == .legacyOnDevice
    )
  }

  @Test
  func converterProducesTheRequestedSpeechFormat() throws {
    let sourceFormat = try #require(
      AVAudioFormat(
        standardFormatWithSampleRate: 48_000,
        channels: 2
      )
    )
    let targetFormat = try #require(
      AVAudioFormat(
        standardFormatWithSampleRate: 16_000,
        channels: 1
      )
    )
    let source = try #require(
      AVAudioPCMBuffer(
        pcmFormat: sourceFormat,
        frameCapacity: 4_800
      )
    )
    source.frameLength = 4_800
    let converter = SpeechAudioBufferConverter(
      targetFormat: targetFormat
    )

    let converted = try converter.convert(
      CapturedAudioBuffer(copying: source)
    )

    #expect(converted.format.sampleRate == 16_000)
    #expect(converted.format.channelCount == 1)
    #expect(converted.frameLength > 0)
  }

  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_RUN_SPEECH_INTEGRATION"
        ] == "1"
    )
  )
  @available(macOS 26, *)
  func modernBackendPreparesTheLocalSystemModel() async throws {
    let factory = AppleSpeechRecognitionSessionFactory()
    try await factory.prepare(locale: .current)
    let clock = ContinuousClock()
    let start = clock.now

    let session = try await factory.makeSession(
      locale: .current
    )
    let warmStartup = start.duration(to: clock.now)
    await session.cancel()
    await factory.shutdown()

    print(
      "Warm local speech session startup: \(warmStartup)"
    )
    #expect(warmStartup < .milliseconds(50))
  }

  /// Reuses one factory across repeated real finalization cycles.
  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_SPEECH_AUDIO_FILE"
        ] != nil
    )
  )
  @available(macOS 26, *)
  func modernBackendRepeatedlyTranscribesLocalAudio()
    async throws
  {
    let path = try #require(
      ProcessInfo.processInfo.environment[
        "HC_SPEECH_AUDIO_FILE"
      ]
    )
    let factory = AppleSpeechRecognitionSessionFactory()

    for _ in 0..<10 {
      let audioFile = try AVAudioFile(
        forReading: URL(fileURLWithPath: path)
      )
      let session = try await factory.makeSession(
        locale: Locale(identifier: "en-US")
      )
      let resultTask = Task {
        var updates: [TranscriptRevision] = []
        for try await update in session.updates {
          updates.append(update)
        }
        return updates
      }

      while audioFile.framePosition < audioFile.length {
        let remaining =
          audioFile.length - audioFile.framePosition
        let capacity = AVAudioFrameCount(
          min(4_096, remaining)
        )
        let buffer = try #require(
          AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: capacity
          )
        )
        try audioFile.read(
          into: buffer,
          frameCount: capacity
        )
        try await session.append(
          try CapturedAudioBuffer(copying: buffer)
        )
      }
      try await session.finish()
      let updates = try await resultTask.value
      let recognized =
        updates.last?.committedText.lowercased() ?? ""

      #expect(recognized.contains("hardware controller"))
      #expect(recognized.contains("local transcription"))
    }

    await factory.shutdown()
  }
}
