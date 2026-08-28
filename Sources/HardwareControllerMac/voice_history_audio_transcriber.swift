@preconcurrency import AVFoundation
import Foundation
import HardwareControllerCore

/// Feeds retained local audio through the same on-device ASR boundary as capture.
public actor AppleVoiceHistoryAudioTranscriber:
  VoiceHistoryAudioTranscribing
{
  private let factory: any SpeechRecognitionSessionCreating

  public init(
    factory: any SpeechRecognitionSessionCreating =
      AppleSpeechRecognitionSessionFactory()
  ) {
    self.factory = factory
  }

  public func transcribe(
    audioURL: URL,
    locale: Locale
  ) async throws -> VoiceHistoryTranscription {
    let file = try AVAudioFile(forReading: audioURL)
    let durationMilliseconds = Int64(
      (Double(file.length) / file.processingFormat.sampleRate * 1_000)
        .rounded()
    )
    let session = try await factory.makeSession(locale: locale)
    let updates = session.updates
    let resultTask = Task {
      var latest = ""
      for try await revision in updates {
        latest = revision.displayText
      }
      return latest
    }

    do {
      try await append(file: file, to: session)
      try await session.finish()
      let text = try await resultTask.value
      let spans =
        durationMilliseconds > 0 && !text.isEmpty
        ? [
          VoiceHistoryTimedSpan(
            startMilliseconds: 0,
            endMilliseconds: durationMilliseconds,
            text: text
          )
        ] : []
      return VoiceHistoryTranscription(text: text, spans: spans)
    } catch {
      resultTask.cancel()
      await session.cancel()
      throw error
    }
  }

  private func append(
    file: AVAudioFile,
    to session: any SpeechRecognitionSession
  ) async throws {
    let frameCapacity: AVAudioFrameCount = 4_096
    while file.framePosition < file.length {
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat,
          frameCapacity: frameCapacity
        )
      else {
        throw SpeechRecognitionBackendError.conversionFailed(
          "Retained audio could not be buffered for recognition."
        )
      }
      try file.read(into: buffer, frameCount: frameCapacity)
      guard buffer.frameLength > 0 else {
        break
      }
      try await session.append(
        CapturedAudioBuffer(copying: buffer)
      )
    }
  }
}
