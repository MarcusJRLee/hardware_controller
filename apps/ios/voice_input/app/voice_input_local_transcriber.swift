import AVFAudio
import Foundation
import HardwareControllerVoiceFFI
import VoiceASRBridge

struct VoiceInputTranscriptSegment: Codable, Equatable, Sendable {
  let startMilliseconds: Int64
  let endMilliseconds: Int64
  let text: String
}

struct VoiceInputRawTranscript: Codable, Equatable, Sendable {
  let text: String
  let segments: [VoiceInputTranscriptSegment]
  let modelPackageID: String
  let modelVersion: String
}

enum VoiceInputTranscriptionError: Error, LocalizedError, Equatable, Sendable {
  case unsupportedAudio
  case noSpeechDetected
  case incompleteTranscript
  case modelLoadFailed
  case inferenceFailed
  case resultLimitExceeded
  case invalidRuntimeResult

  var errorDescription: String? {
    switch self {
    case .unsupportedAudio:
      "The local recording is not readable 16 kHz mono audio."
    case .noSpeechDetected:
      "No speech was detected. The recording remains on this iPhone."
    case .incompleteTranscript:
      "Local speech-to-text stopped before the end of the recording. The recording remains on this iPhone."
    case .modelLoadFailed:
      "The selected local speech-to-text model could not be loaded."
    case .inferenceFailed:
      "Local speech-to-text processing failed. The recording remains on this iPhone."
    case .resultLimitExceeded:
      "The local transcript exceeded its safety limit. The recording remains available."
    case .invalidRuntimeResult:
      "The local speech-to-text runtime returned an invalid result."
    }
  }
}

protocol VoiceInputTranscribing: Sendable {
  func prewarm(model: VoiceInputInstalledModelPackage) async throws
  func transcribe(
    audioURL: URL,
    model: VoiceInputInstalledModelPackage
  ) async throws -> VoiceInputRawTranscript
}

/// Runs the pinned transcribe.cpp runtime on the containing app's completed recording.
actor VoiceInputLocalTranscriber: VoiceInputTranscribing {
  private static let maximumAudioFrameCount = 16_000 * 60 * 30
  private static let maximumTranscriptBytes = 1_048_576
  private static let maximumSegmentCount = 4_096

  /// Runtime diagnostics are process-wide and must be configured before load.
  private static let runtimeConfiguration: UInt32 = {
    #if DEBUG
      voice_asr_runtime_configure_v1(1)
    #else
      voice_asr_runtime_configure_v1(0)
    #endif
  }()

  private let resolver: any PortableASRModelResolving
  private var loadedContext: LoadedContext?

  init(resolver: any PortableASRModelResolving = RustPortableVoiceValidator()) {
    self.resolver = resolver
  }

  func prewarm(model: VoiceInputInstalledModelPackage) throws {
    _ = try context(for: model)
  }

  func transcribe(
    audioURL: URL,
    model: VoiceInputInstalledModelPackage
  ) throws -> VoiceInputRawTranscript {
    let loaded = try context(for: model)
    let samples = try Self.readSamples(from: audioURL)
    var transcript = Data(count: Self.maximumTranscriptBytes)
    var runtimeSegments = [VoiceASRSegmentV1](
      repeating: VoiceASRSegmentV1(),
      count: Self.maximumSegmentCount
    )
    let language = Self.runtimeLanguage(for: model.package.languages)
    let counts = language.withCString { languageBytes in
      transcript.withUnsafeMutableBytes { transcriptBytes in
        runtimeSegments.withUnsafeMutableBufferPointer { segmentBuffer in
          samples.withUnsafeBufferPointer { sampleBuffer in
            var request = VoiceASRRequestV1()
            request.language_utf8 = languageBytes
            request.detect_speech = loaded.detectsSpeech ? 1 : 0
            var output = VoiceASRResultV1()
            output.transcript_utf8 = transcriptBytes.baseAddress?.assumingMemoryBound(
              to: UInt8.self
            )
            output.transcript_capacity = transcriptBytes.count
            output.segments = segmentBuffer.baseAddress
            output.segment_capacity = segmentBuffer.count
            let status = voice_asr_transcribe_v1(
              loaded.handle.pointer,
              sampleBuffer.baseAddress,
              sampleBuffer.count,
              &request,
              &output
            )
            return (status, output.transcript_length, output.segment_count)
          }
        }
      }
    }
    switch counts.0 {
    case VoiceASRStatusOK.rawValue:
      break
    case VoiceASRStatusNoSpeech.rawValue:
      throw VoiceInputTranscriptionError.noSpeechDetected
    case VoiceASRStatusIncompleteTranscript.rawValue:
      throw VoiceInputTranscriptionError.incompleteTranscript
    case VoiceASRStatusBufferTooSmall.rawValue:
      throw VoiceInputTranscriptionError.resultLimitExceeded
    case VoiceASRStatusInferenceFailed.rawValue:
      throw VoiceInputTranscriptionError.inferenceFailed
    default:
      throw VoiceInputTranscriptionError.invalidRuntimeResult
    }
    guard
      counts.1 <= transcript.count,
      counts.2 <= runtimeSegments.count
    else {
      throw VoiceInputTranscriptionError.invalidRuntimeResult
    }
    return try Self.decode(
      transcript: transcript.prefix(counts.1),
      runtimeSegments: runtimeSegments.prefix(counts.2),
      model: model
    )
  }

  private func context(
    for model: VoiceInputInstalledModelPackage
  ) throws -> LoadedContext {
    let resolved = try resolver.resolveFileASRModel(
      at: model.rootURL,
      limits: .standardModelPackage,
      expectedManifestSHA256: model.package.manifestSHA256
    )
    let key = LoadedContext.Key(
      modelPath: resolved.modelURL.path(percentEncoded: false),
      speechDetectionPath: resolved.speechDetectionURL?.path(percentEncoded: false),
      manifestSHA256: model.package.manifestSHA256
    )
    if let loadedContext, loadedContext.key == key {
      return loadedContext
    }
    // Release the previous model before mapping the next one.
    loadedContext = nil
    guard Self.runtimeConfiguration == VoiceASRStatusOK.rawValue else {
      throw VoiceInputTranscriptionError.modelLoadFailed
    }
    let threadCount = UInt32(min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8))
    var newContext: OpaquePointer?
    let status = resolved.modelURL.withUnsafeFileSystemRepresentation { modelPath in
      if let speechDetectionURL = resolved.speechDetectionURL {
        return speechDetectionURL.withUnsafeFileSystemRepresentation { speechPath in
          voice_asr_context_create_v1(modelPath, speechPath, 1, threadCount, &newContext)
        }
      }
      return voice_asr_context_create_v1(modelPath, nil, 1, threadCount, &newContext)
    }
    guard status == VoiceASRStatusOK.rawValue, let newContext else {
      throw VoiceInputTranscriptionError.modelLoadFailed
    }
    let loaded = LoadedContext(
      key: key,
      handle: ASRContextHandle(pointer: newContext),
      detectsSpeech: resolved.speechDetectionURL != nil
    )
    loadedContext = loaded
    return loaded
  }

  private static func readSamples(from audioURL: URL) throws -> [Float] {
    do {
      let file = try AVAudioFile(forReading: audioURL)
      let format = file.processingFormat
      guard
        format.sampleRate == 16_000,
        format.channelCount == 1,
        format.commonFormat == .pcmFormatFloat32,
        file.length > 0,
        file.length <= Int64(maximumAudioFrameCount),
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format,
          frameCapacity: AVAudioFrameCount(file.length)
        )
      else {
        throw VoiceInputTranscriptionError.unsupportedAudio
      }
      try file.read(into: buffer)
      guard
        buffer.frameLength > 0,
        let channel = buffer.floatChannelData?[0]
      else {
        throw VoiceInputTranscriptionError.unsupportedAudio
      }
      let samples = Array(
        UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
      )
      guard samples.allSatisfy(\Float.isFinite) else {
        throw VoiceInputTranscriptionError.unsupportedAudio
      }
      return samples
    } catch let error as VoiceInputTranscriptionError {
      throw error
    } catch {
      throw VoiceInputTranscriptionError.unsupportedAudio
    }
  }

  static func decode(
    transcript: Data.SubSequence,
    runtimeSegments: ArraySlice<VoiceASRSegmentV1>,
    model: VoiceInputInstalledModelPackage
  ) throws -> VoiceInputRawTranscript {
    let transcriptData = Data(transcript)
    guard String(data: transcriptData, encoding: .utf8) != nil else {
      throw VoiceInputTranscriptionError.invalidRuntimeResult
    }
    var segments: [VoiceInputTranscriptSegment] = []
    var expectedOffset = 0
    var previousEndMilliseconds: Int64 = 0
    for runtimeSegment in runtimeSegments {
      let endOffset = runtimeSegment.text_offset.addingReportingOverflow(
        runtimeSegment.text_length
      )
      guard
        !endOffset.overflow,
        runtimeSegment.text_offset == expectedOffset,
        endOffset.partialValue <= transcriptData.count,
        runtimeSegment.start_milliseconds >= 0,
        runtimeSegment.start_milliseconds >= previousEndMilliseconds,
        runtimeSegment.end_milliseconds >= runtimeSegment.start_milliseconds
      else {
        throw VoiceInputTranscriptionError.invalidRuntimeResult
      }
      guard
        let decoded = String(
          data: transcriptData[
            runtimeSegment.text_offset..<endOffset.partialValue
          ],
          encoding: .utf8
        )
      else {
        throw VoiceInputTranscriptionError.invalidRuntimeResult
      }
      let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        segments.append(
          VoiceInputTranscriptSegment(
            startMilliseconds: runtimeSegment.start_milliseconds,
            endMilliseconds: runtimeSegment.end_milliseconds,
            text: text
          )
        )
      }
      expectedOffset = endOffset.partialValue
      previousEndMilliseconds = runtimeSegment.end_milliseconds
    }
    let text = segments.map(\.text).joined(separator: " ")
    guard expectedOffset == transcriptData.count, !text.isEmpty else {
      throw VoiceInputTranscriptionError.inferenceFailed
    }
    return VoiceInputRawTranscript(
      text: text,
      segments: segments,
      modelPackageID: model.package.packageID,
      modelVersion: model.package.version
    )
  }

  static func runtimeLanguage(for languages: [String]) -> String {
    guard languages.count == 1, let language = languages.first else {
      return "auto"
    }
    let primary = language.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
    guard (2...3).contains(primary.count), primary.allSatisfy(\.isLetter) else {
      return "auto"
    }
    return primary.lowercased()
  }

  private struct LoadedContext {
    struct Key: Equatable {
      let modelPath: String
      let speechDetectionPath: String?
      let manifestSHA256: Data
    }

    let key: Key
    let handle: ASRContextHandle
    let detectsSpeech: Bool
  }

  private final class ASRContextHandle {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
      self.pointer = pointer
    }

    deinit {
      voice_asr_context_destroy_v1(pointer)
    }
  }
}
