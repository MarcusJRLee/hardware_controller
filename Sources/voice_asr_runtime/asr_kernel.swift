import Foundation
import VoiceASRBridge

/// One timed span of runtime text with absolute times in the submitted audio.
public struct ASRKernelSegment: Codable, Equatable, Sendable {
  public let startMilliseconds: Int64
  public let endMilliseconds: Int64
  public let text: String

  public init(startMilliseconds: Int64, endMilliseconds: Int64, text: String) {
    self.startMilliseconds = startMilliseconds
    self.endMilliseconds = endMilliseconds
    self.text = text
  }
}

/// Complete runtime text and the segments it was assembled from.
public struct ASRKernelTranscript: Codable, Equatable, Sendable {
  public let text: String
  public let segments: [ASRKernelSegment]

  public init(text: String, segments: [ASRKernelSegment]) {
    self.text = text
    self.segments = segments
  }
}

/// What the loaded model applies to requests.
public struct ASRKernelCapabilities: Codable, Equatable, Sendable {
  public let supportsVocabulary: Bool
  public let supportsSpeechDetection: Bool

  public init(supportsVocabulary: Bool, supportsSpeechDetection: Bool) {
    self.supportsVocabulary = supportsVocabulary
    self.supportsSpeechDetection = supportsSpeechDetection
  }
}

/// One transcription request; see `VoiceASRRequestV1`.
public struct ASRKernelRequest: Codable, Equatable, Sendable {
  public let language: String
  public let vocabulary: [String]
  public let detectSpeech: Bool

  public init(language: String, vocabulary: [String], detectSpeech: Bool) {
    self.language = language
    self.vocabulary = vocabulary
    self.detectSpeech = detectSpeech
  }

  /// Maps BCP 47 tags to the runtime's primary subtag, or `auto` when ambiguous.
  public static func runtimeLanguage(for languages: [String]) -> String {
    guard languages.count == 1, let language = languages.first else {
      return "auto"
    }
    let primary = language.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
    guard (2...3).contains(primary.count), primary.allSatisfy(\.isLetter) else {
      return "auto"
    }
    return primary.lowercased()
  }
}

public enum ASRKernelError: Error, Equatable, Sendable {
  case runtimeConfigurationFailed
  case modelLoadFailed
  case invalidRequest
  case noSpeechDetected
  case incompleteTranscript
  case resultLimitExceeded
  case inferenceFailed
  case invalidRuntimeResult
}

/// Owns one transcribe.cpp context.
///
/// The runtime is not reentrant, so callers must confine an instance to one
/// thread or serial queue at a time.
public final class ASRKernel {
  public static let maximumTranscriptBytes = 1_048_576
  public static let maximumSegmentCount = 4_096
  // Swift cannot import `UINT32_C` macros; the bridge rejects anything above
  // `VOICE_ASR_MAXIMUM_VOCABULARY_TERMS` as an invalid argument regardless.
  public static let maximumVocabularyTerms = 64

  /// Release builds keep runtime diagnostics off standard error.
  private static let runtimeConfiguration: UInt32 = {
    #if DEBUG
      voice_asr_runtime_configure_v1(1)
    #else
      voice_asr_runtime_configure_v1(0)
    #endif
  }()

  public let capabilities: ASRKernelCapabilities
  private let context: OpaquePointer

  public init(
    modelURL: URL,
    speechDetectionURL: URL?,
    useGPU: Bool,
    threadCount: UInt32 = ASRKernel.defaultThreadCount
  ) throws(ASRKernelError) {
    guard Self.runtimeConfiguration == VoiceASRStatusOK.rawValue else {
      throw .runtimeConfigurationFailed
    }
    var created: OpaquePointer?
    let gpu: UInt8 = useGPU ? 1 : 0
    let status = modelURL.withUnsafeFileSystemRepresentation { modelPath in
      guard let speechDetectionURL else {
        return voice_asr_context_create_v1(modelPath, nil, gpu, threadCount, &created)
      }
      return speechDetectionURL.withUnsafeFileSystemRepresentation { speechPath in
        voice_asr_context_create_v1(modelPath, speechPath, gpu, threadCount, &created)
      }
    }
    guard status == VoiceASRStatusOK.rawValue, let created else {
      throw .modelLoadFailed
    }
    var info = VoiceASRContextInfoV1()
    guard voice_asr_context_info_v1(created, &info) == VoiceASRStatusOK.rawValue else {
      voice_asr_context_destroy_v1(created)
      throw .modelLoadFailed
    }
    context = created
    capabilities = ASRKernelCapabilities(
      supportsVocabulary: info.supports_vocabulary == 1,
      supportsSpeechDetection: info.supports_speech_detection == 1
    )
  }

  deinit {
    voice_asr_context_destroy_v1(context)
  }

  public static var defaultThreadCount: UInt32 {
    UInt32(min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8))
  }

  /// Transcribes 16 kHz mono samples in one pass.
  public func transcribe(
    _ samples: [Float],
    request: ASRKernelRequest
  ) throws(ASRKernelError) -> ASRKernelTranscript {
    guard
      !samples.isEmpty,
      request.vocabulary.count <= Self.maximumVocabularyTerms,
      request.language.utf8.count <= 16
    else {
      throw .invalidRequest
    }
    let detectSpeech = request.detectSpeech && capabilities.supportsSpeechDetection
    return try Self.withCStrings(request.vocabulary) { vocabulary throws(ASRKernelError) in
      try request.language.withCString { language throws(ASRKernelError) in
        var bridgeRequest = VoiceASRRequestV1()
        bridgeRequest.language_utf8 = language
        bridgeRequest.vocabulary_utf8 = vocabulary.baseAddress
        bridgeRequest.vocabulary_count = UInt32(request.vocabulary.count)
        bridgeRequest.detect_speech = detectSpeech ? 1 : 0
        return try samples.withUnsafeBufferPointer { buffer throws(ASRKernelError) in
          try Self.readResult { output in
            voice_asr_transcribe_v1(
              context,
              buffer.baseAddress,
              buffer.count,
              &bridgeRequest,
              &output
            )
          }
        }
      }
    }
  }

  /// Runs one bridge call into bounded buffers and validates its result.
  static func readResult(
    run: (inout VoiceASRResultV1) -> UInt32
  ) throws(ASRKernelError) -> ASRKernelTranscript {
    var transcript = Data(count: maximumTranscriptBytes)
    var runtimeSegments = [VoiceASRSegmentV1](
      repeating: VoiceASRSegmentV1(),
      count: maximumSegmentCount
    )
    let (status, length, count) = transcript.withUnsafeMutableBytes { bytes in
      runtimeSegments.withUnsafeMutableBufferPointer { segments in
        var output = VoiceASRResultV1()
        output.transcript_utf8 = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
        output.transcript_capacity = bytes.count
        output.segments = segments.baseAddress
        output.segment_capacity = segments.count
        let status = run(&output)
        return (status, output.transcript_length, output.segment_count)
      }
    }
    switch status {
    case VoiceASRStatusOK.rawValue:
      break
    case VoiceASRStatusNoSpeech.rawValue:
      throw .noSpeechDetected
    case VoiceASRStatusIncompleteTranscript.rawValue:
      throw .incompleteTranscript
    case VoiceASRStatusBufferTooSmall.rawValue:
      throw .resultLimitExceeded
    case VoiceASRStatusInferenceFailed.rawValue:
      throw .inferenceFailed
    case VoiceASRStatusInvalidArgument.rawValue:
      throw .invalidRequest
    default:
      throw .invalidRuntimeResult
    }
    guard length <= transcript.count, count <= runtimeSegments.count else {
      throw .invalidRuntimeResult
    }
    return try decode(
      transcript: transcript.prefix(length),
      runtimeSegments: runtimeSegments.prefix(count).map {
        RuntimeSegment(
          startMilliseconds: $0.start_milliseconds,
          endMilliseconds: $0.end_milliseconds,
          textOffset: $0.text_offset,
          textLength: $0.text_length
        )
      }
    )
  }

  /// Bridge segment fields, separated from the C type so decoding is testable.
  struct RuntimeSegment: Equatable {
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let textOffset: Int
    let textLength: Int
  }

  /// Rejects any segment that is out of order, overlaps, or leaves text unclaimed.
  static func decode(
    transcript: Data.SubSequence,
    runtimeSegments: [RuntimeSegment]
  ) throws(ASRKernelError) -> ASRKernelTranscript {
    let data = Data(transcript)
    guard String(data: data, encoding: .utf8) != nil else {
      throw .invalidRuntimeResult
    }
    var segments: [ASRKernelSegment] = []
    var expectedOffset = 0
    var previousEnd: Int64 = 0
    for segment in runtimeSegments {
      let end = segment.textOffset.addingReportingOverflow(segment.textLength)
      guard
        !end.overflow,
        segment.textOffset == expectedOffset,
        end.partialValue <= data.count,
        segment.startMilliseconds >= previousEnd,
        segment.endMilliseconds >= segment.startMilliseconds,
        let decoded = String(
          data: data[segment.textOffset..<end.partialValue],
          encoding: .utf8
        )
      else {
        throw .invalidRuntimeResult
      }
      let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        segments.append(
          ASRKernelSegment(
            startMilliseconds: segment.startMilliseconds,
            endMilliseconds: segment.endMilliseconds,
            text: text
          )
        )
      }
      expectedOffset = end.partialValue
      previousEnd = segment.endMilliseconds
    }
    let text = segments.map(\.text).joined(separator: " ")
    guard expectedOffset == data.count, !text.isEmpty else {
      throw .inferenceFailed
    }
    return ASRKernelTranscript(text: text, segments: segments)
  }

  /// Exposes null-terminated copies of `strings` for one synchronous call.
  private static func withCStrings<Result>(
    _ strings: [String],
    _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) throws(ASRKernelError) -> Result
  ) throws(ASRKernelError) -> Result {
    let copies = strings.map { strdup($0) }
    defer {
      for copy in copies {
        free(copy)
      }
    }
    guard copies.allSatisfy({ $0 != nil }) else {
      throw .invalidRequest
    }
    let pointers = copies.map { UnsafePointer($0) }
    return try pointers.withUnsafeBufferPointer { buffer throws(ASRKernelError) in
      try body(strings.isEmpty ? UnsafeBufferPointer(start: nil, count: 0) : buffer)
    }
  }
}
