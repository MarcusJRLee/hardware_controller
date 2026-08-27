import Foundation
import Testing

@testable import HardwareControllerVoiceFFI

@Suite("Portable Voice validator")
struct PortableVoiceValidatorTests {
  @Test("Shared archive fixture crosses the linked Rust boundary")
  func validatesSharedArchiveFixture() throws {
    let validator = RustPortableVoiceValidator()
    let fixture = repositoryRoot.appending(
      path: "Tests/cuj/voice_history_archive_v1/valid",
      directoryHint: .isDirectory
    )

    let result = try validator.validateHistoryArchive(
      at: fixture,
      limits: .standardHistoryArchive
    )

    #expect(
      result.sessionID
        == UUID(uuidString: "00000000-0000-4000-8000-000000000001")
    )
    #expect(result.resultCount == 4)
    #expect(result.hasAudio == false)
    #expect(result.verifiedBytes > 0)
    #expect(result.manifestSHA256.count == 32)
  }

  @Test("Shared Model-package fixture crosses the linked Rust boundary")
  func validatesSharedModelPackageFixture() throws {
    let validator = RustPortableVoiceValidator()
    let fixture = repositoryRoot.appending(
      path: "Tests/cuj/voice_model_package_v1/valid",
      directoryHint: .isDirectory
    )

    let result = try validator.validateModelPackage(
      at: fixture,
      limits: .standardModelPackage,
      expectedManifestSHA256: nil
    )

    #expect(result.packageID == "com.longdevity.fixture.streaming_asr")
    #expect(result.runtime == .sherpaONNX)
    #expect(result.stage == .asr)
    #expect(result.capabilities == [.streamingASR, .fileASR])
    #expect(result.fileCount == 2)
    #expect(result.manifestSHA256.count == 32)
  }

  @Test("Typed Rust failures cross the Swift boundary")
  func mapsTypedFailures() throws {
    let validator = RustPortableVoiceValidator()
    let archive = repositoryRoot.appending(
      path: "Tests/cuj/voice_history_archive_v1/valid"
    )
    let model = repositoryRoot.appending(
      path: "Tests/cuj/voice_model_package_v1/valid"
    )

    #expect(throws: PortableVoiceValidationError.limitExceeded) {
      try validator.validateHistoryArchive(
        at: archive,
        limits: PortableVoiceValidationLimits(
          maximumManifestBytes: 1_048_576,
          maximumChecksumBytes: 65_536,
          maximumAudioBytes: 0,
          maximumResultCount: 1
        )
      )
    }
    #expect(throws: PortableVoiceValidationError.limitExceeded) {
      try validator.validateModelPackage(
        at: model,
        limits: PortableModelPackageLimits(
          maximumManifestBytes: 1_048_576,
          maximumInstalledBytes: 1,
          maximumFileCount: 100
        ),
        expectedManifestSHA256: nil
      )
    }
    #expect(throws: PortableVoiceValidationError.integrityMismatch) {
      try validator.validateModelPackage(
        at: model,
        limits: .standardModelPackage,
        expectedManifestSHA256: Data(repeating: 0, count: 32)
      )
    }
    #expect(throws: PortableVoiceValidationError.invalidArgument) {
      try validator.validateModelPackage(
        at: model,
        limits: .standardModelPackage,
        expectedManifestSHA256: Data(repeating: 0, count: 31)
      )
    }
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
