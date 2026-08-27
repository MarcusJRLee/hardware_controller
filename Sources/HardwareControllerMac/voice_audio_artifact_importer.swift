@preconcurrency import AVFoundation
import Foundation

struct VoiceAudioImportInspection: Equatable, Sendable {
  let sourceBytes: Int64
  let durationMilliseconds: Int64
  let retainedAudioBytes: Int64
}

enum VoiceAudioImportInspector {
  static func inspect(
    sourceURL: URL,
    limits: VoiceAudioImportLimits
  ) throws -> VoiceAudioImportInspection {
    let limits = try limits.validated()
    guard sourceURL.isFileURL else {
      throw VoiceAudioImportError.sourceUnavailable
    }
    let values: URLResourceValues
    do {
      values = try sourceURL.resourceValues(
        forKeys: [.isRegularFileKey, .fileSizeKey]
      )
    } catch {
      throw VoiceAudioImportError.sourceUnavailable
    }
    guard values.isRegularFile == true, let fileSize = values.fileSize else {
      throw VoiceAudioImportError.sourceUnavailable
    }
    let sourceBytes = Int64(fileSize)
    guard sourceBytes <= limits.maximumSourceBytes else {
      throw VoiceAudioImportError.sourceTooLarge
    }

    let file: AVAudioFile
    do {
      file = try AVAudioFile(forReading: sourceURL)
    } catch {
      throw VoiceAudioImportError.unsupportedAudio
    }
    let sampleRate = file.processingFormat.sampleRate
    guard file.length > 0, sampleRate.isFinite, sampleRate > 0 else {
      throw VoiceAudioImportError.emptyAudio
    }
    let durationMilliseconds = Int64(
      (Double(file.length) / sampleRate * 1_000).rounded()
    )
    guard durationMilliseconds > 0 else {
      throw VoiceAudioImportError.emptyAudio
    }
    guard durationMilliseconds <= limits.maximumDurationMilliseconds else {
      throw VoiceAudioImportError.durationTooLong
    }
    let stream = file.processingFormat.streamDescription.pointee
    let bytesPerFrame = Int64(stream.mBytesPerFrame)
    let planeCount =
      file.processingFormat.isInterleaved
      ? Int64(1) : Int64(file.processingFormat.channelCount)
    guard
      bytesPerFrame > 0,
      planeCount > 0,
      file.length <= Int64.max / bytesPerFrame / planeCount
    else {
      throw VoiceAudioImportError.unsupportedAudio
    }
    let retainedAudioBytes = file.length * bytesPerFrame * planeCount
    guard retainedAudioBytes <= limits.maximumRetainedAudioBytes else {
      throw VoiceAudioImportError.retainedAudioTooLarge
    }
    return VoiceAudioImportInspection(
      sourceBytes: sourceBytes,
      durationMilliseconds: durationMilliseconds,
      retainedAudioBytes: retainedAudioBytes
    )
  }
}

/// Streams supported local audio into the canonical app-owned CAF artifact.
actor VoiceAudioArtifactImporter {
  func importAudio(
    from sourceURL: URL,
    sessionID: UUID,
    audioDirectory: URL,
    limits: VoiceAudioImportLimits
  ) throws -> URL {
    _ = try VoiceAudioImportInspector.inspect(
      sourceURL: sourceURL,
      limits: limits
    )
    let partialURL = audioDirectory.appending(
      path: "\(sessionID.uuidString).partial"
    )
    let finalURL = audioDirectory.appending(
      path: "\(sessionID.uuidString).caf"
    )
    guard
      !FileManager.default.fileExists(atPath: partialURL.path),
      !FileManager.default.fileExists(atPath: finalURL.path)
    else {
      throw VoiceAudioImportError.couldNotStore
    }

    do {
      let source = try AVAudioFile(forReading: sourceURL)
      var destination: AVAudioFile? = try AVAudioFile(
        forWriting: partialURL,
        settings: source.processingFormat.settings,
        commonFormat: source.processingFormat.commonFormat,
        interleaved: source.processingFormat.isInterleaved
      )
      let frameCapacity: AVAudioFrameCount = 4_096
      while source.framePosition < source.length {
        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: source.processingFormat,
            frameCapacity: frameCapacity
          )
        else {
          throw VoiceAudioImportError.unsupportedAudio
        }
        try source.read(into: buffer, frameCount: frameCapacity)
        guard buffer.frameLength > 0 else {
          break
        }
        try destination?.write(from: buffer)
      }
      guard source.framePosition == source.length else {
        throw VoiceAudioImportError.couldNotStore
      }
      destination = nil
      let retainedSize = try partialURL.resourceValues(
        forKeys: [.fileSizeKey]
      ).fileSize.map(Int64.init)
      guard
        let retainedSize,
        retainedSize <= limits.maximumRetainedAudioBytes
      else {
        throw VoiceAudioImportError.retainedAudioTooLarge
      }
      let handle = try FileHandle(forWritingTo: partialURL)
      try handle.synchronize()
      try handle.close()
      try FileManager.default.moveItem(at: partialURL, to: finalURL)
      return finalURL
    } catch let failure as VoiceAudioImportError {
      try? FileManager.default.removeItem(at: partialURL)
      throw failure
    } catch {
      try? FileManager.default.removeItem(at: partialURL)
      throw VoiceAudioImportError.couldNotStore
    }
  }
}
