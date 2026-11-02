import Foundation
import HardwareControllerASRProtocol
import HardwareControllerVoiceFFI
import VoiceASRRuntime

/// Loads one validated Model package and transcribes with it.
///
/// Not thread-safe: `ASRServiceHandler` confines every call to one serial
/// queue, matching the runtime's single-threaded contract.
public final class ASRServiceCore {
  /// Creates a kernel; tests substitute a fake.
  public typealias KernelFactory = (
    _ model: PortableResolvedASRModel,
    _ useGPU: Bool
  ) throws(ASRKernelError) -> any ASRTranscribing

  private let resolver: any PortableASRModelResolving
  private let makeKernel: KernelFactory
  private var loaded: (manifestSHA256: Data, useGPU: Bool, kernel: any ASRTranscribing)?

  public init(
    resolver: any PortableASRModelResolving = RustPortableVoiceValidator(),
    makeKernel: @escaping KernelFactory = { model, useGPU throws(ASRKernelError) in
      try ASRKernel(
        modelURL: model.modelURL,
        speechDetectionURL: model.speechDetectionURL,
        useGPU: useGPU
      )
    }
  ) {
    self.resolver = resolver
    self.makeKernel = makeKernel
  }

  public func load(_ message: Data) -> Data {
    ASRServiceCodec.encode(reply { () throws(ASRServiceFailure) in try loadModel(message) })
  }

  public func transcribe(_ message: Data, samples: Data) -> Data {
    ASRServiceCodec.encode(
      reply { () throws(ASRServiceFailure) in try transcribeSamples(message, samples: samples) }
    )
  }

  public func unload() {
    loaded = nil
  }

  private func loadModel(_ message: Data) throws(ASRServiceFailure) -> ASRLoadedModel {
    let request = try ASRServiceCodec.decode(ASRLoadRequest.self, from: message)
    guard request.protocolVersion == ASRServiceIdentity.protocolVersion else {
      throw .unsupportedProtocolVersion
    }
    if let loaded,
      loaded.manifestSHA256 == request.expectedManifestSHA256,
      loaded.useGPU == request.useGPU
    {
      return Self.describe(
        loaded.kernel, manifestSHA256: loaded.manifestSHA256, useGPU: loaded.useGPU)
    }
    // Release the previous model before mapping the next one.
    loaded = nil
    let model: PortableResolvedASRModel
    do {
      model = try resolver.resolveFileASRModel(
        at: URL(filePath: request.packageRootPath, directoryHint: .isDirectory),
        limits: .standardModelPackage,
        expectedManifestSHA256: request.expectedManifestSHA256
      )
    } catch {
      throw .packageInvalid
    }
    let kernel: any ASRTranscribing
    do {
      kernel = try makeKernel(model, request.useGPU)
    } catch {
      throw .modelLoadFailed
    }
    loaded = (request.expectedManifestSHA256, request.useGPU, kernel)
    return Self.describe(
      kernel, manifestSHA256: request.expectedManifestSHA256, useGPU: request.useGPU)
  }

  private func transcribeSamples(
    _ message: Data,
    samples: Data
  ) throws(ASRServiceFailure) -> ASRServiceTranscript {
    let request = try ASRServiceCodec.decode(ASRTranscribeRequest.self, from: message)
    guard request.protocolVersion == ASRServiceIdentity.protocolVersion else {
      throw .unsupportedProtocolVersion
    }
    guard let loaded else {
      throw .notLoaded
    }
    let audio = try ASRAudioSamples.decode(samples)
    let start = ContinuousClock.now
    do {
      let transcript = try loaded.kernel.transcribe(
        audio,
        request: ASRKernelRequest(
          language: request.language,
          vocabulary: request.vocabulary,
          detectSpeech: request.detectSpeech
        )
      )
      return ASRServiceTranscript(
        text: transcript.text,
        segments: transcript.segments.map {
          ASRServiceSegment(
            startMilliseconds: $0.startMilliseconds,
            endMilliseconds: $0.endMilliseconds,
            text: $0.text
          )
        },
        decodeMilliseconds: Self.milliseconds(ContinuousClock.now - start)
      )
    } catch {
      throw Self.failure(for: error)
    }
  }

  static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1_000_000_000_000_000
  }

  static func failure(for error: ASRKernelError) -> ASRServiceFailure {
    switch error {
    case .runtimeConfigurationFailed, .modelLoadFailed:
      .modelLoadFailed
    case .invalidRequest:
      .invalidMessage
    case .noSpeechDetected:
      .noSpeechDetected
    case .incompleteTranscript:
      .incompleteTranscript
    case .resultLimitExceeded:
      .resultLimitExceeded
    case .inferenceFailed, .invalidRuntimeResult:
      .inferenceFailed
    }
  }

  private static func describe(
    _ kernel: any ASRTranscribing,
    manifestSHA256: Data,
    useGPU: Bool
  ) -> ASRLoadedModel {
    ASRLoadedModel(
      manifestSHA256: manifestSHA256,
      supportsVocabulary: kernel.capabilities.supportsVocabulary,
      supportsSpeechDetection: kernel.capabilities.supportsSpeechDetection,
      usesGPU: useGPU
    )
  }

  private func reply<Value>(
    _ body: () throws(ASRServiceFailure) -> Value
  ) -> ASRServiceReply<Value> {
    do {
      return .success(try body())
    } catch {
      return .failure(error)
    }
  }
}

/// The kernel surface the service uses, so tests need no model files.
public protocol ASRTranscribing: AnyObject {
  var capabilities: ASRKernelCapabilities { get }
  func transcribe(
    _ samples: [Float],
    request: ASRKernelRequest
  ) throws(ASRKernelError) -> ASRKernelTranscript
}

extension ASRKernel: ASRTranscribing {}

/// Confines every request to one serial queue and answers over XPC.
public final class ASRServiceHandler: NSObject, ASRServiceXPCProtocol, @unchecked Sendable {
  // `core` is touched only on `queue`, which is what makes this type Sendable.
  private let queue = DispatchQueue(label: "\(ASRServiceIdentity.serviceName).kernel")
  private let core: ASRServiceCore

  public init(core: ASRServiceCore = ASRServiceCore()) {
    self.core = core
  }

  public func load(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
    queue.async { reply(self.core.load(request)) }
  }

  public func transcribe(
    _ request: Data,
    samples: Data,
    reply: @escaping @Sendable (Data) -> Void
  ) {
    queue.async { reply(self.core.transcribe(request, samples: samples)) }
  }

  public func unload(reply: @escaping @Sendable () -> Void) {
    queue.async {
      self.core.unload()
      reply()
    }
  }
}

/// Accepts connections from the containing app, which launchd limits to.
public final class ASRServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
  private let handler = ASRServiceHandler()

  public func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: ASRServiceXPCProtocol.self)
    connection.exportedObject = handler
    connection.resume()
    return true
  }
}
