import Foundation

public enum ASRServiceIdentity {
  /// Bundle identifiers allow no underscores, so the service name is one word.
  public static let serviceName = "com.longdevity.hardwarecontroller.asrservice"
  public static let protocolVersion = 1
}

/// The service's remote interface.
///
/// Every request and reply is a versioned JSON envelope so both processes stay
/// typed. Audio travels as raw float32 bytes; JSON would triple its size.
@objc public protocol ASRServiceXPCProtocol {
  func load(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
  func transcribe(
    _ request: Data,
    samples: Data,
    reply: @escaping @Sendable (Data) -> Void
  )
  func unload(reply: @escaping @Sendable () -> Void)
}

public struct ASRLoadRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let packageRootPath: String
  /// The digest recorded at install; the service revalidates every file against it.
  public let expectedManifestSHA256: Data
  public let useGPU: Bool

  public init(
    packageRootPath: String,
    expectedManifestSHA256: Data,
    useGPU: Bool,
    protocolVersion: Int = ASRServiceIdentity.protocolVersion
  ) {
    self.protocolVersion = protocolVersion
    self.packageRootPath = packageRootPath
    self.expectedManifestSHA256 = expectedManifestSHA256
    self.useGPU = useGPU
  }
}

/// The package the service validated and loaded.
public struct ASRLoadedModel: Codable, Equatable, Sendable {
  public let manifestSHA256: Data
  public let supportsVocabulary: Bool
  public let supportsSpeechDetection: Bool
  public let usesGPU: Bool

  public init(
    manifestSHA256: Data,
    supportsVocabulary: Bool,
    supportsSpeechDetection: Bool,
    usesGPU: Bool
  ) {
    self.manifestSHA256 = manifestSHA256
    self.supportsVocabulary = supportsVocabulary
    self.supportsSpeechDetection = supportsSpeechDetection
    self.usesGPU = usesGPU
  }
}

public struct ASRTranscribeRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let language: String
  public let vocabulary: [String]
  public let detectSpeech: Bool

  public init(
    language: String,
    vocabulary: [String],
    detectSpeech: Bool,
    protocolVersion: Int = ASRServiceIdentity.protocolVersion
  ) {
    self.protocolVersion = protocolVersion
    self.language = language
    self.vocabulary = vocabulary
    self.detectSpeech = detectSpeech
  }
}

public struct ASRServiceSegment: Codable, Equatable, Sendable {
  public let startMilliseconds: Int64
  public let endMilliseconds: Int64
  public let text: String

  public init(startMilliseconds: Int64, endMilliseconds: Int64, text: String) {
    self.startMilliseconds = startMilliseconds
    self.endMilliseconds = endMilliseconds
    self.text = text
  }
}

public struct ASRServiceTranscript: Codable, Equatable, Sendable {
  public let text: String
  public let segments: [ASRServiceSegment]
  /// Decode time inside the service, so callers can separate IPC cost.
  public let decodeMilliseconds: Double

  public init(text: String, segments: [ASRServiceSegment], decodeMilliseconds: Double = 0) {
    self.text = text
    self.segments = segments
    self.decodeMilliseconds = decodeMilliseconds
  }
}

public enum ASRServiceFailure: String, Codable, Error, Equatable, Sendable {
  case unsupportedProtocolVersion
  case invalidMessage
  case invalidAudio
  case packageInvalid
  case modelLoadFailed
  case notLoaded
  case noSpeechDetected
  case incompleteTranscript
  case resultLimitExceeded
  case inferenceFailed
}

public enum ASRServiceReply<Value: Codable & Equatable & Sendable>:
  Codable, Equatable, Sendable
{
  case success(Value)
  case failure(ASRServiceFailure)
}

public enum ASRServiceCodec {
  public static func encode<Value: Encodable>(_ value: Value) -> Data {
    // These message types contain only strings, numbers, and Data, which
    // JSONEncoder always represents; an empty payload is rejected on decode.
    (try? JSONEncoder().encode(value)) ?? Data()
  }

  public static func decode<Value: Decodable>(
    _ type: Value.Type,
    from data: Data
  ) throws(ASRServiceFailure) -> Value {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw .invalidMessage
    }
  }
}

/// 16 kHz mono float32 audio as it crosses the process boundary.
public enum ASRAudioSamples {
  public static let sampleRate = 16_000
  /// Thirty minutes bounds one request at 115 MB.
  public static let maximumSampleCount = 16_000 * 60 * 30

  // Both ends run on this Mac and every supported Mac is little-endian, so
  // samples cross as raw bytes; a per-sample loop cost 14 ms for 84 s of audio.
  private static let hostIsLittleEndian = 1.littleEndian == 1

  public static func encode(_ samples: [Float]) -> Data {
    precondition(hostIsLittleEndian, "ASR audio crosses as little-endian float32.")
    return samples.withUnsafeBytes { Data($0) }
  }

  public static func decode(_ data: Data) throws(ASRServiceFailure) -> [Float] {
    let width = MemoryLayout<Float>.size
    guard
      hostIsLittleEndian,
      !data.isEmpty,
      data.count.isMultiple(of: width),
      data.count / width <= maximumSampleCount
    else {
      throw .invalidAudio
    }
    var samples = [Float](repeating: 0, count: data.count / width)
    _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    guard samples.allSatisfy({ $0.isFinite }) else {
      throw .invalidAudio
    }
    return samples
  }
}
