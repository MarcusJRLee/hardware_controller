@preconcurrency import AVFoundation
import Foundation
import HardwareControllerCore
@preconcurrency import Speech

/// Models the legacy recognizer's expected and unexpected termination paths.
struct LegacyRecognitionLifecycle: Sendable {
  private enum Phase: Sendable {
    case acceptingInput
    case finalizing
    case stopped
  }

  private var phase = Phase.acceptingInput

  var acceptsInput: Bool {
    phase == .acceptingInput
  }

  var isStopped: Bool {
    phase == .stopped
  }

  /// Begins finalization only while input is still accepted.
  mutating func beginFinalization() -> Bool {
    guard phase == .acceptingInput else {
      return false
    }
    phase = .finalizing
    return true
  }

  /// Stops once and reports whether cleanup remains necessary.
  mutating func stop() -> Bool {
    guard phase != .stopped else {
      return false
    }
    phase = .stopped
    return true
  }

  /// Stops on a final result and reports whether finalization expected it.
  mutating func receiveFinalResult() -> Bool {
    let wasExpected = phase == .finalizing
    phase = .stopped
    return wasExpected
  }
}

actor LegacyOnDeviceSpeechRecognitionSession:
  SpeechRecognitionSession
{
  nonisolated let updates: AsyncThrowingStream<TranscriptRevision, any Error>

  private let recognizer: SFSpeechRecognizer
  private let request: SFSpeechAudioBufferRecognitionRequest
  private let updateContinuation:
    AsyncThrowingStream<
      TranscriptRevision,
      any Error
    >.Continuation
  private var recognitionTask: SFSpeechRecognitionTask?
  private var lifecycle = LegacyRecognitionLifecycle()
  private var resultsEnded = false

  /// Creates and starts one fail-closed on-device recognition session.
  static func make(
    locale: Locale,
    vocabularyHints: [String] = []
  ) async throws -> LegacyOnDeviceSpeechRecognitionSession {
    guard
      let recognizer = SFSpeechRecognizer(locale: locale)
    else {
      throw SpeechRecognitionBackendError.localeUnsupported
    }
    try validateReadiness(
      permission: LegacySpeechPermission.status,
      recognizerAvailable: recognizer.isAvailable,
      supportsOnDeviceRecognition:
        recognizer.supportsOnDeviceRecognition
    )

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.addsPunctuation = true
    request.taskHint = .dictation
    request.contextualStrings = vocabularyHints

    let (updates, continuation) =
      AsyncThrowingStream<
        TranscriptRevision,
        any Error
      >.makeStream(
        bufferingPolicy: .bufferingNewest(32)
      )
    let session = LegacyOnDeviceSpeechRecognitionSession(
      recognizer: recognizer,
      request: request,
      updates: updates,
      updateContinuation: continuation
    )
    await session.start()
    return session
  }

  /// Stores one validated recognizer and its bounded result stream.
  private init(
    recognizer: SFSpeechRecognizer,
    request: SFSpeechAudioBufferRecognitionRequest,
    updates: AsyncThrowingStream<TranscriptRevision, any Error>,
    updateContinuation:
      AsyncThrowingStream<
        TranscriptRevision,
        any Error
      >.Continuation
  ) {
    self.recognizer = recognizer
    self.request = request
    self.updates = updates
    self.updateContinuation = updateContinuation
  }

  /// Appends one immutable captured sample while input remains open.
  func append(_ audio: CapturedAudioBuffer) throws {
    guard lifecycle.acceptsInput else {
      throw SpeechRecognitionBackendError.unavailable
    }
    request.append(try audio.makePCMBuffer())
  }

  /// Ends audio and waits within the shared finalization bound.
  func finish() async throws {
    guard lifecycle.beginFinalization() else {
      return
    }
    request.endAudio()

    for _ in 0..<150 {
      if resultsEnded {
        _ = lifecycle.stop()
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }

    _ = lifecycle.stop()
    recognitionTask?.cancel()
    updateContinuation.finish(
      throwing:
        SpeechRecognitionBackendError
        .recognitionFailed(
          "On-device recognition did not finish."
        )
    )
    throw
      SpeechRecognitionBackendError
      .recognitionFailed(
        "On-device recognition did not finish."
      )
  }

  /// Cancels recognition and finishes result delivery exactly once.
  func cancel() {
    guard lifecycle.stop() else {
      return
    }
    recognitionTask?.cancel()
    updateContinuation.finish()
  }

  /// Starts the legacy callback task and forwards values into actor isolation.
  private func start() {
    recognitionTask = recognizer.recognitionTask(
      with: request
    ) { [weak self] result, error in
      let text =
        result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let errorDescription = error?.localizedDescription
      Task {
        await self?.receive(
          text: text,
          isFinal: isFinal,
          errorDescription: errorDescription
        )
      }
    }
  }

  /// Converts one callback into an explicit lifecycle transition.
  private func receive(
    text: String?,
    isFinal: Bool,
    errorDescription: String?
  ) {
    guard !lifecycle.isStopped else {
      return
    }
    if let text, !text.isEmpty {
      updateContinuation.yield(
        isFinal ? .committed(text) : .provisional(text)
      )
    }
    if isFinal {
      resultsEnded = true
      if lifecycle.receiveFinalResult() {
        updateContinuation.finish()
      } else {
        updateContinuation.finish(
          throwing:
            SpeechRecognitionBackendError
            .recognitionInterrupted
        )
      }
      return
    }
    if let errorDescription {
      resultsEnded = true
      updateContinuation.finish(
        throwing:
          SpeechRecognitionBackendError
          .recognitionFailed(errorDescription)
      )
    }
  }

  /// Rejects permission, availability, or local-model uncertainty.
  static func validateReadiness(
    permission: PermissionStatus,
    recognizerAvailable: Bool,
    supportsOnDeviceRecognition: Bool
  ) throws {
    guard permission == .authorized else {
      throw SpeechRecognitionBackendError.unavailable
    }
    guard recognizerAvailable else {
      throw SpeechRecognitionBackendError.unavailable
    }
    guard supportsOnDeviceRecognition else {
      throw SpeechRecognitionBackendError.modelUnavailable
    }
  }
}
