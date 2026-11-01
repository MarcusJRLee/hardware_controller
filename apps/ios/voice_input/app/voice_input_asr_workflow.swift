import AVFAudio
import Foundation

actor VoiceInputASRWorkflow {
  /// Live audio may start a few frames after the file recorder and stop a few
  /// frames before it; any larger shortfall means the tap missed speech.
  static let liveCoverageToleranceSamples = 8_000

  private let modelProvider: any VoiceInputASRModelProviding
  private let transcriber: any VoiceInputTranscribing
  private let liveTranscriber: (any VoiceInputLiveTranscribing)?
  private let recordedSampleCount: @Sendable (URL) throws -> Int
  private var liveModel: VoiceInputInstalledModelPackage?

  init(
    modelProvider: any VoiceInputASRModelProviding,
    transcriber: any VoiceInputTranscribing,
    liveTranscriber: (any VoiceInputLiveTranscribing)? = nil,
    recordedSampleCount: @escaping @Sendable (URL) throws -> Int = {
      Int(try AVAudioFile(forReading: $0).length)
    }
  ) {
    self.modelProvider = modelProvider
    self.transcriber = transcriber
    self.liveTranscriber = liveTranscriber
    self.recordedSampleCount = recordedSampleCount
  }

  func prewarmSelectedModel() async throws {
    let model = try await modelProvider.selectedASRModel()
    try await transcriber.prewarm(model: model)
  }

  /// Starts best-effort live decoding. Returns false when it is unavailable.
  func beginLiveTranscription() async -> Bool {
    guard
      let liveTranscriber,
      let model = try? await modelProvider.selectedASRModel(),
      await liveTranscriber.beginLive(model: model)
    else {
      liveModel = nil
      return false
    }
    liveModel = model
    return true
  }

  func feedLiveTranscription(_ samples: [Float]) async {
    guard liveModel != nil, let liveTranscriber else {
      return
    }
    if await !liveTranscriber.feedLive(samples) {
      liveModel = nil
    }
  }

  func cancelLiveTranscription() async {
    liveModel = nil
    await liveTranscriber?.cancelLive()
  }

  /// Uses the live result only when it succeeded for the same model and covers
  /// the whole recording; otherwise the completed file is transcribed.
  func transcribe(audioURL: URL) async throws -> VoiceInputRawTranscript {
    let model = try await modelProvider.selectedASRModel()
    if let live = await finishLive(model: model),
      let recorded = try? recordedSampleCount(audioURL),
      live.receivedSampleCount + Self.liveCoverageToleranceSamples >= recorded
    {
      return live.transcript
    }
    return try await transcriber.transcribe(audioURL: audioURL, model: model)
  }

  private func finishLive(
    model: VoiceInputInstalledModelPackage
  ) async -> VoiceInputLiveTranscript? {
    guard let liveModel, let liveTranscriber else {
      return nil
    }
    self.liveModel = nil
    guard liveModel == model else {
      await liveTranscriber.cancelLive()
      return nil
    }
    return await liveTranscriber.finishLive(model: model)
  }
}
