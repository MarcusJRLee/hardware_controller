import AVFoundation
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct VoiceHistoryAudioTranscriberTest {
  @Test
  func retainedAudioProducesOneReplayableTimedTranscript() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "history_transcriber_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let url = root.appending(path: "fixture.caf")
    let captured = try makeVoiceAudioFixture()
    let buffer = try captured.makePCMBuffer()
    let file = try AVAudioFile(
      forWriting: url,
      settings: buffer.format.settings
    )
    try file.write(from: buffer)
    let session = HistoryRecognitionSession()
    let transcriber = AppleVoiceHistoryAudioTranscriber(
      factory: HistoryRecognitionFactory(session: session)
    )

    let output = try await transcriber.transcribe(
      audioURL: url,
      locale: Locale(identifier: "en_US")
    )

    #expect(output.text == "Retained transcript.")
    #expect(
      output.spans == [
        VoiceHistoryTimedSpan(
          startMilliseconds: 0,
          endMilliseconds: 100,
          text: "Retained transcript."
        )
      ])
    #expect(await session.appendCount > 0)
    #expect(await session.finishCount == 1)
  }
}

private struct HistoryRecognitionFactory:
  SpeechRecognitionSessionCreating
{
  let session: HistoryRecognitionSession

  func makeSession(
    locale: Locale
  ) async throws -> any SpeechRecognitionSession {
    session
  }

  func shutdown() async {}
}

private actor HistoryRecognitionSession: SpeechRecognitionSession {
  nonisolated let updates: AsyncThrowingStream<TranscriptRevision, any Error>
  private let continuation: AsyncThrowingStream<TranscriptRevision, any Error>.Continuation
  private(set) var appendCount = 0
  private(set) var finishCount = 0

  init() {
    (updates, continuation) = AsyncThrowingStream.makeStream()
  }

  func append(_ audio: CapturedAudioBuffer) async throws {
    appendCount += 1
  }

  func finish() async throws {
    finishCount += 1
    continuation.yield(.committed("Retained transcript."))
    continuation.finish()
  }

  func cancel() async {
    continuation.finish()
  }
}
