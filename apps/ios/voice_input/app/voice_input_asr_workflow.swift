import Foundation

actor VoiceInputASRWorkflow {
  private let modelProvider: any VoiceInputASRModelProviding
  private let transcriber: any VoiceInputTranscribing

  init(
    modelProvider: any VoiceInputASRModelProviding,
    transcriber: any VoiceInputTranscribing
  ) {
    self.modelProvider = modelProvider
    self.transcriber = transcriber
  }

  func prewarmSelectedModel() async throws {
    let model = try await modelProvider.selectedASRModel()
    try await transcriber.prewarm(model: model)
  }

  func transcribe(audioURL: URL) async throws -> VoiceInputRawTranscript {
    let model = try await modelProvider.selectedASRModel()
    return try await transcriber.transcribe(audioURL: audioURL, model: model)
  }
}
