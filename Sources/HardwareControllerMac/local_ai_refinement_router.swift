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
  private static let remoteProviderMessage =
    "Remote-capable providers are disabled in local-only mode."
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
    async let appleReadiness = Self.readiness(
      apple,
      expectedProvider: .appleOnDevice,
      settings: settings,
      locale: locale
    )
    async let ollamaReadiness = Self.readiness(
      ollama,
      expectedProvider: .ollama,
      settings: settings,
      locale: locale
    )
    return await LocalAIReadinessSnapshot(
      apple: appleReadiness,
      ollama: ollamaReadiness
    )
  }

  public func prepare(settings: LocalAISettings) async throws {
    try await validated(settings.provider).prepare(settings: settings)
  }

  public func refine(
    _ request: LocalAIRefinementRequest,
    settings: LocalAISettings
  ) async throws -> LocalAIRefinementResponse {
    let response = try await validated(settings.provider).refine(
      request,
      settings: settings
    )
    guard response.provider == settings.provider else {
      throw LocalAIRefinementFailure.providerUnavailable(
        "The selected provider returned mismatched identity evidence."
      )
    }
    return response
  }

  public func release(settings: LocalAISettings) async {
    guard let provider = try? validated(settings.provider) else {
      return
    }
    await provider.release(settings: settings)
  }

  public func shutdown() async {
    async let appleShutdown: Void = Self.shutdown(
      apple,
      expectedProvider: .appleOnDevice
    )
    async let ollamaShutdown: Void = Self.shutdown(
      ollama,
      expectedProvider: .ollama
    )
    _ = await (appleShutdown, ollamaShutdown)
  }

  private func validated(
    _ provider: LocalAIProviderKind
  ) throws -> any TranscriptRefining {
    let refiner: any TranscriptRefining =
      switch provider {
      case .appleOnDevice:
        apple
      case .ollama:
        ollama
      }
    guard refiner.capability.provider == provider else {
      throw LocalAIRefinementFailure.providerUnavailable(
        "The selected provider declared mismatched identity evidence."
      )
    }
    guard refiner.capability.locality.permitsContentInLocalOnlyMode else {
      throw LocalAIRefinementFailure.remoteProviderRejected
    }
    return refiner
  }

  private nonisolated static func readiness(
    _ refiner: any TranscriptRefining,
    expectedProvider: LocalAIProviderKind,
    settings: LocalAISettings,
    locale: Locale
  ) async -> LocalAIProviderReadiness {
    guard refiner.capability.provider == expectedProvider else {
      return unavailable(
        expectedProvider,
        message: "The provider declared mismatched identity evidence."
      )
    }
    guard refiner.capability.locality.permitsContentInLocalOnlyMode else {
      return unavailable(
        expectedProvider,
        message: remoteProviderMessage
      )
    }
    let readiness = await refiner.readiness(
      settings: settings,
      locale: locale
    )
    guard readiness.provider == expectedProvider else {
      return unavailable(
        expectedProvider,
        message: "The provider returned mismatched identity evidence."
      )
    }
    return readiness
  }

  private nonisolated static func shutdown(
    _ refiner: any TranscriptRefining,
    expectedProvider: LocalAIProviderKind
  ) async {
    guard
      refiner.capability.provider == expectedProvider,
      refiner.capability.locality.permitsContentInLocalOnlyMode
    else {
      return
    }
    await refiner.shutdown()
  }

  private nonisolated static func unavailable(
    _ provider: LocalAIProviderKind,
    message: String
  ) -> LocalAIProviderReadiness {
    LocalAIProviderReadiness(
      provider: provider,
      state: .unavailable(message)
    )
  }
}
