import Foundation
import HardwareControllerASRProtocol
import HardwareControllerVoiceFFI
import Testing
import VoiceASRRuntime

@testable import HardwareControllerASRServiceKit

struct ASRServiceCoreTest {
  private static let digest = Data(repeating: 7, count: 32)

  /// Loading revalidates the package, then transcription returns typed text.
  @Test
  func loadsThenTranscribes() throws {
    let harness = Harness()
    let loaded = try harness.load()
    #expect(
      loaded
        == ASRLoadedModel(
          manifestSHA256: Self.digest, supportsVocabulary: false, supportsSpeechDetection: true,
          usesGPU: true))
    guard case .success(let transcript) = try harness.transcribe() else {
      Issue.record("Expected a transcript.")
      return
    }
    #expect(transcript.text == "send it")
    #expect(
      transcript.segments == [
        ASRServiceSegment(startMilliseconds: 0, endMilliseconds: 500, text: "send it")
      ])
    #expect(transcript.decodeMilliseconds >= 0)
    #expect(harness.resolver.calls == 1)
  }

  /// An identical load reuses the kernel; a GPU change reloads it.
  @Test
  func reloadsOnlyWhenTheRequestChanges() throws {
    let harness = Harness()
    _ = try harness.load()
    _ = try harness.load()
    #expect(harness.kernels.count == 1)
    _ = try harness.load(useGPU: false)
    #expect(harness.kernels.map(\.useGPU) == [true, false])
  }

  @Test
  func failuresAreTyped() throws {
    #expect(try Harness().transcribe() == .failure(.notLoaded))
    let invalid = Harness(resolverFails: true)
    #expect(
      invalid.decode(ASRLoadedModel.self, invalid.core.load(invalid.loadMessage()))
        == .failure(.packageInvalid))
    let unloadable = Harness(kernelFails: true)
    #expect(
      unloadable.decode(ASRLoadedModel.self, unloadable.core.load(unloadable.loadMessage()))
        == .failure(.modelLoadFailed))
    let stale = Harness()
    #expect(
      stale.decode(ASRLoadedModel.self, stale.core.load(stale.loadMessage(version: 99)))
        == .failure(.unsupportedProtocolVersion))
  }

  /// Every kernel error maps to the failure the app acts on.
  @Test(arguments: [
    (ASRKernelError.noSpeechDetected, ASRServiceFailure.noSpeechDetected),
    (.incompleteTranscript, .incompleteTranscript),
    (.resultLimitExceeded, .resultLimitExceeded),
    (.inferenceFailed, .inferenceFailed),
    (.invalidRuntimeResult, .inferenceFailed),
    (.invalidRequest, .invalidMessage),
    (.modelLoadFailed, .modelLoadFailed),
  ])
  func kernelErrorsMap(error: ASRKernelError, failure: ASRServiceFailure) throws {
    let harness = Harness(transcribeError: error)
    _ = try harness.load()
    #expect(try harness.transcribe() == .failure(failure))
  }

  @Test
  func unloadReleasesTheKernel() throws {
    let harness = Harness()
    _ = try harness.load()
    harness.core.unload()
    #expect(try harness.transcribe() == .failure(.notLoaded))
  }
}

private final class Harness {
  final class Resolver: PortableASRModelResolving, @unchecked Sendable {
    let fails: Bool
    var calls = 0
    init(fails: Bool) { self.fails = fails }
    func resolveFileASRModel(
      at root: URL,
      limits: PortableModelPackageLimits,
      expectedManifestSHA256: Data
    ) throws -> PortableResolvedASRModel {
      calls += 1
      if fails { throw PortableVoiceValidationError.integrityMismatch }
      return PortableResolvedASRModel(
        modelURL: root.appending(path: "model.gguf"), speechDetectionURL: nil)
    }
  }

  final class Kernel: ASRTranscribing {
    let useGPU: Bool
    let error: ASRKernelError?
    let capabilities = ASRKernelCapabilities(
      supportsVocabulary: false, supportsSpeechDetection: true)
    init(useGPU: Bool, error: ASRKernelError?) {
      self.useGPU = useGPU
      self.error = error
    }
    func transcribe(_ samples: [Float], request: ASRKernelRequest) throws(ASRKernelError)
      -> ASRKernelTranscript
    {
      if let error { throw error }
      return ASRKernelTranscript(
        text: "send it",
        segments: [ASRKernelSegment(startMilliseconds: 0, endMilliseconds: 500, text: "send it")]
      )
    }
  }

  final class Kernels {
    var created: [Kernel] = []
  }

  let resolver: Resolver
  let core: ASRServiceCore
  private let made = Kernels()

  var kernels: [Kernel] { made.created }

  init(
    resolverFails: Bool = false, kernelFails: Bool = false, transcribeError: ASRKernelError? = nil
  ) {
    resolver = Resolver(fails: resolverFails)
    let made = made
    core = ASRServiceCore(resolver: resolver) { _, useGPU throws(ASRKernelError) in
      if kernelFails { throw .modelLoadFailed }
      let kernel = Kernel(useGPU: useGPU, error: transcribeError)
      made.created.append(kernel)
      return kernel
    }
  }

  func loadMessage(useGPU: Bool = true, version: Int = ASRServiceIdentity.protocolVersion) -> Data {
    ASRServiceCodec.encode(
      ASRLoadRequest(
        packageRootPath: "/tmp/package",
        expectedManifestSHA256: Data(repeating: 7, count: 32),
        useGPU: useGPU,
        protocolVersion: version
      )
    )
  }

  func load(useGPU: Bool = true) throws -> ASRLoadedModel {
    guard
      case .success(let loaded) = decode(
        ASRLoadedModel.self, core.load(loadMessage(useGPU: useGPU)))
    else {
      throw ASRServiceFailure.modelLoadFailed
    }
    return loaded
  }

  func transcribe() throws -> ASRServiceReply<ASRServiceTranscript> {
    decode(
      ASRServiceTranscript.self,
      core.transcribe(
        ASRServiceCodec.encode(
          ASRTranscribeRequest(language: "en", vocabulary: [], detectSpeech: true)),
        samples: ASRAudioSamples.encode([0, 0.1, -0.1])
      )
    )
  }

  func decode<Value>(_ type: Value.Type, _ data: Data) -> ASRServiceReply<Value> {
    (try? ASRServiceCodec.decode(ASRServiceReply<Value>.self, from: data))
      ?? .failure(.invalidMessage)
  }
}
