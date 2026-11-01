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

final class VoiceInputASRWorkflowLiveTest: XCTestCase {
  private let installed = makeInstalledASRPackage()
  private let audioURL = URL(fileURLWithPath: "/private/live.caf")

  private func transcript(_ text: String) -> VoiceInputRawTranscript {
    VoiceInputRawTranscript(
      text: text,
      segments: [],
      modelPackageID: installed.package.packageID,
      modelVersion: installed.package.version
    )
  }

  private func workflow(
    live: StubLiveTranscriber?,
    file: StubTranscriber,
    recordedSamples: Int = 16_000
  ) -> VoiceInputASRWorkflow {
    VoiceInputASRWorkflow(
      modelProvider: StubASRModelProvider(result: .success(installed)),
      transcriber: file,
      liveTranscriber: live,
      recordedSampleCount: { _ in recordedSamples }
    )
  }

  func testCoveringLiveResultSkipsFileTranscription() async throws {
    let live = StubLiveTranscriber(result: transcript("live"), receivedSamples: 16_000)
    let file = StubTranscriber(result: .success(transcript("file")))
    let workflow = workflow(live: live, file: file)

    let began = await workflow.beginLiveTranscription()
    await workflow.feedLiveTranscription([0.1, 0.2])
    let result = try await workflow.transcribe(audioURL: audioURL)

    XCTAssertTrue(began)
    XCTAssertEqual(result.text, "live")
    XCTAssertEqual(live.fedSampleCount, 2)
    XCTAssertEqual(file.transcriptions, [])
  }

  func testShortLiveCoverageFallsBackToTheRecording() async throws {
    let live = StubLiveTranscriber(result: transcript("live"), receivedSamples: 1_000)
    let file = StubTranscriber(result: .success(transcript("file")))
    let workflow = workflow(live: live, file: file, recordedSamples: 16_000)

    _ = await workflow.beginLiveTranscription()
    let result = try await workflow.transcribe(audioURL: audioURL)

    XCTAssertEqual(result.text, "file")
    XCTAssertEqual(file.transcriptions.count, 1)
  }

  func testEndedOrUnavailableLiveDecodingFallsBackToTheRecording() async throws {
    let failedFeed = StubLiveTranscriber(
      result: transcript("live"),
      receivedSamples: 16_000,
      acceptsFeed: false
    )
    let file = StubTranscriber(result: .success(transcript("file")))
    let ended = workflow(live: failedFeed, file: file)
    _ = await ended.beginLiveTranscription()
    await ended.feedLiveTranscription([0])
    let endedResult = try await ended.transcribe(audioURL: audioURL)
    XCTAssertEqual(endedResult.text, "file")
    XCTAssertEqual(failedFeed.finishCount, 0)

    let unavailable = workflow(live: nil, file: file)
    let began = await unavailable.beginLiveTranscription()
    let unavailableResult = try await unavailable.transcribe(audioURL: audioURL)
    XCTAssertFalse(began)
    XCTAssertEqual(unavailableResult.text, "file")
  }

  func testCancelledLiveDecodingIsNeverFinished() async throws {
    let live = StubLiveTranscriber(result: transcript("live"), receivedSamples: 16_000)
    let file = StubTranscriber(result: .success(transcript("file")))
    let workflow = workflow(live: live, file: file)

    _ = await workflow.beginLiveTranscription()
    await workflow.cancelLiveTranscription()
    let result = try await workflow.transcribe(audioURL: audioURL)

    XCTAssertEqual(result.text, "file")
    XCTAssertEqual(live.finishCount, 0)
    XCTAssertEqual(live.cancelCount, 1)
  }
}

private final class StubLiveTranscriber: VoiceInputLiveTranscribing, Sendable {
  private struct State: Sendable {
    var fedSampleCount = 0
    var finishCount = 0
    var cancelCount = 0
  }

  private let state = Mutex(State())
  private let result: VoiceInputRawTranscript
  private let receivedSamples: Int
  private let acceptsFeed: Bool

  init(result: VoiceInputRawTranscript, receivedSamples: Int, acceptsFeed: Bool = true) {
    self.result = result
    self.receivedSamples = receivedSamples
    self.acceptsFeed = acceptsFeed
  }

  var fedSampleCount: Int { state.withLock { $0.fedSampleCount } }
  var finishCount: Int { state.withLock { $0.finishCount } }
  var cancelCount: Int { state.withLock { $0.cancelCount } }

  func beginLive(model _: VoiceInputInstalledModelPackage) async -> Bool { true }

  func feedLive(_ samples: [Float]) async -> Bool {
    state.withLock { $0.fedSampleCount += samples.count }
    return acceptsFeed
  }

  func finishLive(
    model _: VoiceInputInstalledModelPackage
  ) async -> VoiceInputLiveTranscript? {
    state.withLock { $0.finishCount += 1 }
    return VoiceInputLiveTranscript(transcript: result, receivedSampleCount: receivedSamples)
  }

  func cancelLive() async {
    state.withLock { $0.cancelCount += 1 }
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
      packageID: "com.longdevity.test.asr",
      version: "1",
      displayName: "Test ASR",
      languages: ["en-US"],
      runtime: .transcribeCPP,
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
