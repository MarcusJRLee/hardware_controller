import Foundation
import HardwareControllerVoiceFFI
import Synchronization
import XCTest

@testable import VoiceInput

final class VoiceInputASRWorkflowTest: XCTestCase {
  func testSelectedModelIsPrewarmedAndUsedForLocalAudio() async throws {
    let installed = makeInstalledASRPackage()
    let provider = StubASRModelProvider(result: .success(installed))
    let transcriber = StubTranscriber(
      result: .success(
        VoiceInputRawTranscript(
          text: "local result",
          segments: [],
          modelPackageID: installed.package.packageID,
          modelVersion: installed.package.version
        )
      )
    )
    let workflow = VoiceInputASRWorkflow(
      modelProvider: provider,
      transcriber: transcriber
    )
    let audioURL = URL(fileURLWithPath: "/private/local.caf")

    try await workflow.prewarmSelectedModel()
    let result = try await workflow.transcribe(audioURL: audioURL)

    XCTAssertEqual(result.text, "local result")
    XCTAssertEqual(transcriber.prewarmedModels, [installed])
    XCTAssertEqual(transcriber.transcriptions, [TranscriptionCall(audioURL, installed)])
  }

  func testMissingSelectionDoesNotInvokeTranscriber() async {
    let provider = StubASRModelProvider(
      result: .failure(VoiceInputASRModelRegistryError.noSelection)
    )
    let transcriber = StubTranscriber(
      result: .failure(VoiceInputTranscriptionError.inferenceFailed)
    )
    let workflow = VoiceInputASRWorkflow(
      modelProvider: provider,
      transcriber: transcriber
    )

    do {
      _ = try await workflow.transcribe(
        audioURL: URL(fileURLWithPath: "/private/local.caf")
      )
      XCTFail("Missing selection must fail before inference.")
    } catch {
      XCTAssertEqual(error as? VoiceInputASRModelRegistryError, .noSelection)
    }
    XCTAssertEqual(transcriber.transcriptions, [])
  }
}

private struct StubASRModelProvider: VoiceInputASRModelProviding {
  let result: Result<VoiceInputInstalledModelPackage, Error>

  func selectedASRModel() async throws -> VoiceInputInstalledModelPackage {
    try result.get()
  }
}

private final class StubTranscriber: VoiceInputTranscribing, Sendable {
  private struct State: Sendable {
    var prewarmedModels: [VoiceInputInstalledModelPackage] = []
    var transcriptions: [TranscriptionCall] = []
  }

  private let state = Mutex(State())
  private let result: Result<VoiceInputRawTranscript, Error>

  init(result: Result<VoiceInputRawTranscript, Error>) {
    self.result = result
  }

  var prewarmedModels: [VoiceInputInstalledModelPackage] {
    state.withLock { $0.prewarmedModels }
  }

  var transcriptions: [TranscriptionCall] {
    state.withLock { $0.transcriptions }
  }

  func prewarm(model: VoiceInputInstalledModelPackage) async throws {
    state.withLock { $0.prewarmedModels.append(model) }
  }

  func transcribe(
    audioURL: URL,
    model: VoiceInputInstalledModelPackage
  ) async throws -> VoiceInputRawTranscript {
    state.withLock { $0.transcriptions.append(TranscriptionCall(audioURL, model)) }
    return try result.get()
  }
}

private struct TranscriptionCall: Equatable, Sendable {
  let audioURL: URL
  let model: VoiceInputInstalledModelPackage

  init(_ audioURL: URL, _ model: VoiceInputInstalledModelPackage) {
    self.audioURL = audioURL
    self.model = model
  }
}

func makeInstalledASRPackage() -> VoiceInputInstalledModelPackage {
  VoiceInputInstalledModelPackage(
    package: PortableModelPackage(
      packageID: "com.longdevity.test.whisper",
      version: "1",
      displayName: "Test Whisper",
      languages: ["en-US"],
      runtime: .whisperCPP,
      stage: .asr,
      capabilities: [.fileASR],
      spdxExpression: "MIT",
      noticeFile: "NOTICE.txt",
      sourceURL: "https://example.invalid",
      fileCount: 2,
      verifiedBytes: 2,
      minimumMemoryBytes: 1,
      recommendedMemoryBytes: 1,
      manifestSHA256: Data(repeating: 1, count: 32)
    ),
    rootURL: URL(fileURLWithPath: "/private/model"),
    publisherVerified: false
  )
}
