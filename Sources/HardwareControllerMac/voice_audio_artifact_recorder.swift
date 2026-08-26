@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Serializes bounded audio writes away from capture and delivery executors.
final class VoiceAudioArtifactRecorder: Sendable {
  private let continuation: AsyncStream<CapturedAudioBuffer>.Continuation
  private let worker: Task<Result<URL?, VoiceSessionHistoryError>, Never>
  private let overflowed = Mutex(false)

  init(sessionID: UUID, audioDirectory: URL) {
    let (stream, continuation) = AsyncStream.makeStream(
      of: CapturedAudioBuffer.self,
      bufferingPolicy: .bufferingOldest(512)
    )
    self.continuation = continuation
    let partialURL = audioDirectory.appending(
      path: "\(sessionID.uuidString).partial"
    )
    let finalURL = audioDirectory.appending(
      path: "\(sessionID.uuidString).caf"
    )
    worker = Task.detached(priority: .utility) {
      await Self.write(
        stream,
        partialURL: partialURL,
        finalURL: finalURL
      )
    }
  }

  func append(_ audio: CapturedAudioBuffer) {
    if case .dropped = continuation.yield(audio) {
      overflowed.withLock { $0 = true }
    }
  }

  func stopRetainingAudio() {
    continuation.finish()
    let worker = worker
    Task.detached(priority: .utility) {
      let result = await worker.value
      Self.removeArtifact(from: result)
    }
  }

  func finishRetainingAudio() async throws -> URL? {
    continuation.finish()
    let result = await worker.value
    guard !overflowed.withLock({ $0 }) else {
      Self.removeArtifact(from: result)
      throw VoiceSessionHistoryError.audioUnavailable(
        "Voice History could not keep up with microphone audio."
      )
    }
    return try result.get()
  }

  func discard() async {
    continuation.finish()
    let result = await worker.value
    Self.removeArtifact(from: result)
  }

  private static func removeArtifact(
    from result: Result<URL?, VoiceSessionHistoryError>
  ) {
    guard case .success(let url?) = result else {
      return
    }
    try? FileManager.default.removeItem(at: url)
  }

  private static func write(
    _ stream: AsyncStream<CapturedAudioBuffer>,
    partialURL: URL,
    finalURL: URL
  ) async -> Result<URL?, VoiceSessionHistoryError> {
    do {
      var file: AVAudioFile?
      var wroteAudio = false
      for await captured in stream {
        let buffer = try captured.makePCMBuffer()
        if file == nil {
          file = try AVAudioFile(
            forWriting: partialURL,
            settings: buffer.format.settings,
            commonFormat: buffer.format.commonFormat,
            interleaved: buffer.format.isInterleaved
          )
        }
        try file?.write(from: buffer)
        wroteAudio = true
      }
      file = nil
      guard wroteAudio else {
        return .success(nil)
      }
      let fileHandle = try FileHandle(forWritingTo: partialURL)
      try fileHandle.synchronize()
      try fileHandle.close()
      try FileManager.default.moveItem(
        at: partialURL,
        to: finalURL
      )
      return .success(finalURL)
    } catch {
      try? FileManager.default.removeItem(at: partialURL)
      return .failure(
        .audioUnavailable(
          "Voice History could not finalize the local audio artifact."
        )
      )
    }
  }
}
