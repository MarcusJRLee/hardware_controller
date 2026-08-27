import Foundation
import VoiceFFIBridge

public struct PortableVoiceValidationLimits: Equatable, Sendable {
  public static let standardHistoryArchive = PortableVoiceValidationLimits(
    maximumManifestBytes: 16 * 1_024 * 1_024,
    maximumChecksumBytes: 256 * 1_024,
    maximumAudioBytes: 2 * 1_024 * 1_024 * 1_024,
    maximumResultCount: 10_000
  )

  public let maximumManifestBytes: UInt64
  public let maximumChecksumBytes: UInt64
  public let maximumAudioBytes: UInt64
  public let maximumResultCount: UInt32

  public init(
    maximumManifestBytes: UInt64,
    maximumChecksumBytes: UInt64,
    maximumAudioBytes: UInt64,
    maximumResultCount: UInt32
  ) {
    self.maximumManifestBytes = maximumManifestBytes
    self.maximumChecksumBytes = maximumChecksumBytes
    self.maximumAudioBytes = maximumAudioBytes
    self.maximumResultCount = maximumResultCount
  }
}

public struct PortableVoiceHistoryArchive: Equatable, Sendable {
  public let sessionID: UUID
  public let resultCount: UInt32
  public let hasAudio: Bool
  public let verifiedBytes: UInt64
  public let manifestSHA256: Data

  public init(
    sessionID: UUID,
    resultCount: UInt32,
    hasAudio: Bool,
    verifiedBytes: UInt64,
    manifestSHA256: Data
  ) {
    self.sessionID = sessionID
    self.resultCount = resultCount
    self.hasAudio = hasAudio
    self.verifiedBytes = verifiedBytes
    self.manifestSHA256 = manifestSHA256
  }
}

public struct PortableModelPackageLimits: Equatable, Sendable {
  public static let standardModelPackage = PortableModelPackageLimits(
    maximumManifestBytes: 1_024 * 1_024,
    maximumInstalledBytes: 8 * 1_024 * 1_024 * 1_024,
    maximumFileCount: 4_096
  )

  public let maximumManifestBytes: UInt64
  public let maximumInstalledBytes: UInt64
  public let maximumFileCount: UInt32

  public init(
    maximumManifestBytes: UInt64,
    maximumInstalledBytes: UInt64,
    maximumFileCount: UInt32
  ) {
    self.maximumManifestBytes = maximumManifestBytes
    self.maximumInstalledBytes = maximumInstalledBytes
    self.maximumFileCount = maximumFileCount
  }
}

public enum PortableModelRuntime: UInt32, Equatable, Sendable {
  case sherpaONNX = 1
  case whisperCPP = 2
  case mistralRS = 3
  case llamaCPP = 4
}

public enum PortableModelStage: UInt32, Equatable, Sendable {
  case asr = 1
  case formatting = 2
  case vad = 3
}

public struct PortableModelCapabilities:
  OptionSet,
  Equatable,
  Sendable
{
  public static let streamingASR = PortableModelCapabilities(rawValue: 1)
  public static let fileASR = PortableModelCapabilities(rawValue: 2)
  public static let formatting = PortableModelCapabilities(rawValue: 4)
  public static let vad = PortableModelCapabilities(rawValue: 8)

  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }
}

public struct PortableModelPackage: Equatable, Sendable {
  public let packageID: String
  public let version: String
  public let displayName: String
  public let runtime: PortableModelRuntime
  public let stage: PortableModelStage
  public let capabilities: PortableModelCapabilities
  public let spdxExpression: String
  public let noticeFile: String
  public let sourceURL: String
  public let fileCount: UInt32
  public let verifiedBytes: UInt64
  public let minimumMemoryBytes: UInt64
  public let recommendedMemoryBytes: UInt64
  public let manifestSHA256: Data
}

public enum PortableVoiceValidationError:
  Error,
  Equatable,
  Sendable
{
  case invalidArgument
  case invalidPath
  case invalidRoot
  case invalidManifest
  case limitExceeded
  case invalidInventory
  case integrityMismatch
  case invalidIdentity
  case inputOutputFailure
  case internalFailure
  case unexpectedStatus(UInt32)
}

public protocol PortableVoiceHistoryArchiveValidating: Sendable {
  func validateHistoryArchive(
    at root: URL,
    limits: PortableVoiceValidationLimits
  ) throws -> PortableVoiceHistoryArchive
}

public struct RustPortableVoiceValidator:
  PortableVoiceHistoryArchiveValidating,
  Sendable
{
  public init() {}

  public func validateHistoryArchive(
    at root: URL,
    limits: PortableVoiceValidationLimits
  ) throws -> PortableVoiceHistoryArchive {
    let pathBytes = Array(root.path(percentEncoded: false).utf8)
    var request = VoiceHistoryArchiveRequestV1()
    request.root_path_length = pathBytes.count
    request.maximum_manifest_bytes = limits.maximumManifestBytes
    request.maximum_checksum_bytes = limits.maximumChecksumBytes
    request.maximum_audio_bytes = limits.maximumAudioBytes
    request.maximum_result_count = limits.maximumResultCount
    var output = VoiceHistoryArchiveInfoV1()
    let status = pathBytes.withUnsafeBufferPointer { path in
      request.root_path_utf8 = path.baseAddress
      return voice_history_archive_validate_v1(&request, &output)
    }
    guard status == VoiceFFIBridgeStatusOK.rawValue else {
      throw Self.error(for: status)
    }
    guard output.has_audio <= 1 else {
      throw PortableVoiceValidationError.internalFailure
    }
    return PortableVoiceHistoryArchive(
      sessionID: Self.uuid(from: output.session_id),
      resultCount: output.result_count,
      hasAudio: output.has_audio == 1,
      verifiedBytes: output.verified_bytes,
      manifestSHA256: Self.data(from: output.manifest_sha256)
    )
  }

  public func validateModelPackage(
    at root: URL,
    limits: PortableModelPackageLimits,
    expectedManifestSHA256: Data?
  ) throws -> PortableModelPackage {
    try Self.validateModelConstants()
    if let expectedManifestSHA256, expectedManifestSHA256.count != 32 {
      throw PortableVoiceValidationError.invalidArgument
    }
    let pathBytes = Array(root.path(percentEncoded: false).utf8)
    var request = VoiceModelPackageRequestV1()
    request.root_path_length = pathBytes.count
    request.maximum_manifest_bytes = limits.maximumManifestBytes
    request.maximum_installed_bytes = limits.maximumInstalledBytes
    request.maximum_file_count = limits.maximumFileCount
    if let expectedManifestSHA256 {
      request.has_expected_manifest_sha256 = 1
      _ = withUnsafeMutableBytes(of: &request.expected_manifest_sha256) { target in
        expectedManifestSHA256.copyBytes(to: target)
      }
    }

    return try callModelValidatorWithBuffers(
      pathBytes: pathBytes,
      request: &request
    )
  }

  private static func error(for status: UInt32) -> PortableVoiceValidationError {
    switch status {
    case VoiceFFIBridgeStatusNullPointer.rawValue,
      VoiceFFIBridgeStatusInvalidArgument.rawValue:
      .invalidArgument
    case VoiceFFIBridgeStatusInvalidUtf8Path.rawValue:
      .invalidPath
    case VoiceFFIBridgeStatusInvalidModelPackageRoot.rawValue:
      .invalidRoot
    case VoiceFFIBridgeStatusInvalidModelPackageManifest.rawValue:
      .invalidManifest
    case VoiceFFIBridgeStatusModelPackageLimitExceeded.rawValue:
      .limitExceeded
    case VoiceFFIBridgeStatusModelPackageInventoryInvalid.rawValue:
      .invalidInventory
    case VoiceFFIBridgeStatusModelPackageDigestMismatch.rawValue:
      .integrityMismatch
    case VoiceFFIBridgeStatusModelPackageIoFailure.rawValue:
      .inputOutputFailure
    case VoiceFFIBridgeStatusInvalidHistoryArchiveRoot.rawValue:
      .invalidRoot
    case VoiceFFIBridgeStatusInvalidHistoryArchiveManifest.rawValue:
      .invalidManifest
    case VoiceFFIBridgeStatusHistoryArchiveLimitExceeded.rawValue:
      .limitExceeded
    case VoiceFFIBridgeStatusHistoryArchiveInventoryInvalid.rawValue:
      .invalidInventory
    case VoiceFFIBridgeStatusHistoryArchiveIntegrityMismatch.rawValue:
      .integrityMismatch
    case VoiceFFIBridgeStatusHistoryArchiveIdentityInvalid.rawValue:
      .invalidIdentity
    case VoiceFFIBridgeStatusHistoryArchiveIoFailure.rawValue:
      .inputOutputFailure
    case VoiceFFIBridgeStatusInternalFailure.rawValue:
      .internalFailure
    default:
      .unexpectedStatus(status)
    }
  }

  private static func uuid(
    from bytes: (
      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
  ) -> UUID {
    UUID(uuid: bytes)
  }

  private static func data<T>(from value: T) -> Data {
    var value = value
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private static func validateModelConstants() throws {
    guard
      PortableModelRuntime.sherpaONNX.rawValue
        == VoiceFFIBridgeModelRuntimeSherpaOnnx.rawValue,
      PortableModelRuntime.whisperCPP.rawValue
        == VoiceFFIBridgeModelRuntimeWhisperCpp.rawValue,
      PortableModelRuntime.mistralRS.rawValue
        == VoiceFFIBridgeModelRuntimeMistralRs.rawValue,
      PortableModelRuntime.llamaCPP.rawValue
        == VoiceFFIBridgeModelRuntimeLlamaCpp.rawValue,
      PortableModelStage.asr.rawValue == VoiceFFIBridgeModelStageAsr.rawValue,
      PortableModelStage.formatting.rawValue
        == VoiceFFIBridgeModelStageFormatting.rawValue,
      PortableModelStage.vad.rawValue == VoiceFFIBridgeModelStageVad.rawValue,
      PortableModelCapabilities.streamingASR.rawValue
        == VoiceFFIBridgeModelCapabilityStreamingAsr.rawValue,
      PortableModelCapabilities.fileASR.rawValue
        == VoiceFFIBridgeModelCapabilityFileAsr.rawValue,
      PortableModelCapabilities.formatting.rawValue
        == VoiceFFIBridgeModelCapabilityFormatting.rawValue,
      PortableModelCapabilities.vad.rawValue
        == VoiceFFIBridgeModelCapabilityVad.rawValue
    else {
      throw PortableVoiceValidationError.internalFailure
    }
  }

  private func callModelValidator(
    pathBytes: [UInt8],
    request: inout VoiceModelPackageRequestV1,
    output: inout VoiceModelPackageInfoV1
  ) -> UInt32 {
    pathBytes.withUnsafeBufferPointer { path in
      request.root_path_utf8 = path.baseAddress
      return voice_model_package_validate_v1(&request, &output)
    }
  }

  private func callModelValidatorWithBuffers(
    pathBytes: [UInt8],
    request: inout VoiceModelPackageRequestV1
  ) throws -> PortableModelPackage {
    // These capacities equal the Rust admission maxima, avoiding a second
    // complete package hash solely to negotiate six small text buffers.
    var packageID = Data(count: 128)
    var version = Data(count: 64)
    var displayName = Data(count: 128)
    var spdxExpression = Data(count: 256)
    var noticeFile = Data(count: 1_024)
    var sourceURL = Data(count: 2_048)
    let metadata = try packageID.withUnsafeMutableBytes { packageIDBytes in
      try version.withUnsafeMutableBytes { versionBytes in
        try displayName.withUnsafeMutableBytes { displayNameBytes in
          try spdxExpression.withUnsafeMutableBytes { spdxBytes in
            try noticeFile.withUnsafeMutableBytes { noticeBytes in
              try sourceURL.withUnsafeMutableBytes { sourceBytes in
                var output = VoiceModelPackageInfoV1()
                output.package_id = Self.utf8Buffer(packageIDBytes)
                output.version = Self.utf8Buffer(versionBytes)
                output.display_name = Self.utf8Buffer(displayNameBytes)
                output.spdx_expression = Self.utf8Buffer(spdxBytes)
                output.notice_file = Self.utf8Buffer(noticeBytes)
                output.source_url = Self.utf8Buffer(sourceBytes)
                let status = callModelValidator(
                  pathBytes: pathBytes,
                  request: &request,
                  output: &output
                )
                guard status == VoiceFFIBridgeStatusOK.rawValue else {
                  if status == VoiceFFIBridgeStatusBufferTooSmall.rawValue {
                    throw PortableVoiceValidationError.internalFailure
                  }
                  throw Self.error(for: status)
                }
                guard
                  let runtime = PortableModelRuntime(rawValue: output.runtime),
                  let stage = PortableModelStage(rawValue: output.stage),
                  output.capability_mask & ~UInt32(0x0F) == 0,
                  output.package_id.length <= packageIDBytes.count,
                  output.version.length <= versionBytes.count,
                  output.display_name.length <= displayNameBytes.count,
                  output.spdx_expression.length <= spdxBytes.count,
                  output.notice_file.length <= noticeBytes.count,
                  output.source_url.length <= sourceBytes.count
                else {
                  throw PortableVoiceValidationError.internalFailure
                }
                return ModelOutputMetadata(
                  runtime: runtime,
                  stage: stage,
                  packageIDLength: output.package_id.length,
                  versionLength: output.version.length,
                  displayNameLength: output.display_name.length,
                  spdxExpressionLength: output.spdx_expression.length,
                  noticeFileLength: output.notice_file.length,
                  sourceURLLength: output.source_url.length,
                  capabilityMask: output.capability_mask,
                  fileCount: output.file_count,
                  verifiedBytes: output.verified_bytes,
                  minimumMemoryBytes: output.minimum_memory_bytes,
                  recommendedMemoryBytes: output.recommended_memory_bytes,
                  manifestSHA256: Self.data(from: output.manifest_sha256)
                )
              }
            }
          }
        }
      }
    }
    return PortableModelPackage(
      packageID: String(
        decoding: packageID.prefix(metadata.packageIDLength),
        as: UTF8.self
      ),
      version: String(
        decoding: version.prefix(metadata.versionLength),
        as: UTF8.self
      ),
      displayName: String(
        decoding: displayName.prefix(metadata.displayNameLength),
        as: UTF8.self
      ),
      runtime: metadata.runtime,
      stage: metadata.stage,
      capabilities: PortableModelCapabilities(
        rawValue: metadata.capabilityMask
      ),
      spdxExpression: String(
        decoding: spdxExpression.prefix(metadata.spdxExpressionLength),
        as: UTF8.self
      ),
      noticeFile: String(
        decoding: noticeFile.prefix(metadata.noticeFileLength),
        as: UTF8.self
      ),
      sourceURL: String(
        decoding: sourceURL.prefix(metadata.sourceURLLength),
        as: UTF8.self
      ),
      fileCount: metadata.fileCount,
      verifiedBytes: metadata.verifiedBytes,
      minimumMemoryBytes: metadata.minimumMemoryBytes,
      recommendedMemoryBytes: metadata.recommendedMemoryBytes,
      manifestSHA256: metadata.manifestSHA256
    )
  }

  private static func utf8Buffer(
    _ bytes: UnsafeMutableRawBufferPointer
  ) -> VoiceUtf8BufferV1 {
    VoiceUtf8BufferV1(
      bytes: bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
      capacity: bytes.count,
      length: 0
    )
  }
}

private struct ModelOutputMetadata {
  let runtime: PortableModelRuntime
  let stage: PortableModelStage
  let packageIDLength: Int
  let versionLength: Int
  let displayNameLength: Int
  let spdxExpressionLength: Int
  let noticeFileLength: Int
  let sourceURLLength: Int
  let capabilityMask: UInt32
  let fileCount: UInt32
  let verifiedBytes: UInt64
  let minimumMemoryBytes: UInt64
  let recommendedMemoryBytes: UInt64
  let manifestSHA256: Data
}
