import Foundation
import HardwareControllerCore

public protocol LocalAIRefinementRouting: Sendable {
  func readiness(
    settings: LocalAISettings,
    locale: Locale
  ) async -> LocalAIReadinessSnapshot

  func prepare(settings: LocalAISettings) async throws

  func refine(
    _ request: LocalAIRefinementRequest,
    settings: LocalAISettings
  ) async throws -> LocalAIRefinementResponse

  func release(settings: LocalAISettings) async

  func shutdown() async
}

extension LocalAIRefinementRouting {
  public func release(settings: LocalAISettings) async {}

  public func shutdown() async {}
}

public actor LocalAIRefinementRouter: LocalAIRefinementRouting {
  private let apple: any TranscriptRefining
  private let ollama: any TranscriptRefining

  public init(
    apple: any TranscriptRefining = AppleFoundationModelRefiner(),
    ollama: any TranscriptRefining = OllamaLocalAIRefiner()
  ) {
    self.apple = apple
    self.ollama = ollama
  }

  public func readiness(
    settings: LocalAISettings,
    locale: Locale
  ) async -> LocalAIReadinessSnapshot {
    async let appleReadiness = apple.readiness(
      settings: settings,
      locale: locale
    )
    async let ollamaReadiness = ollama.readiness(
      settings: settings,
      locale: locale
    )
    return await LocalAIReadinessSnapshot(
      apple: appleReadiness,
      ollama: ollamaReadiness
    )
  }

  public func prepare(settings: LocalAISettings) async throws {
    try await selected(settings.provider).prepare(settings: settings)
  }

  public func refine(
    _ request: LocalAIRefinementRequest,
    settings: LocalAISettings
  ) async throws -> LocalAIRefinementResponse {
    try await selected(settings.provider).refine(
      request,
      settings: settings
    )
  }

  public func release(settings: LocalAISettings) async {
    await selected(settings.provider).release(settings: settings)
  }

  public func shutdown() async {
    async let appleShutdown: Void = apple.shutdown()
    async let ollamaShutdown: Void = ollama.shutdown()
    _ = await (appleShutdown, ollamaShutdown)
  }

  private func selected(
    _ provider: LocalAIProviderKind
  ) -> any TranscriptRefining {
    provider == .appleOnDevice ? apple : ollama
  }
}
