import Foundation
import HardwareControllerCore

#if canImport(FoundationModels)
  import FoundationModels
#endif

public actor AppleFoundationModelRefiner: TranscriptRefining {
  private let promptBuilder: VersionedLocalAIPromptBuilder

  private var preparedSessionStorage: AnyObject?

  public init(
    promptBuilder: VersionedLocalAIPromptBuilder =
      VersionedLocalAIPromptBuilder()
  ) {
    self.promptBuilder = promptBuilder
  }

  public func readiness(
    settings: LocalAISettings,
    locale: Locale
  ) async -> LocalAIProviderReadiness {
    guard #available(macOS 26, *) else {
      return unavailable(
        "Apple On-Device requires macOS 26 or later."
      )
    }
    #if canImport(FoundationModels)
      let model = SystemLanguageModel(
        useCase: .general,
        guardrails: .permissiveContentTransformations
      )
      guard model.supportsLocale(locale) else {
        return unavailable(
          "Apple On-Device does not support the current language."
        )
      }
      switch model.availability {
      case .available:
        return LocalAIProviderReadiness(
          provider: .appleOnDevice,
          state: .ready
        )
      case .unavailable(let reason):
        return unavailable(message(for: reason))
      }
    #else
      return unavailable(
        "Apple On-Device is unavailable in this build."
      )
    #endif
  }

  public func prepare(settings: LocalAISettings) async throws {
    guard #available(macOS 26, *) else {
      throw LocalAIRefinementFailure.providerUnavailable(
        "Apple On-Device requires macOS 26 or later."
      )
    }
    #if canImport(FoundationModels)
      let availability = await readiness(
        settings: settings,
        locale: .current
      )
      guard availability.state.canRun else {
        throw failure(for: availability.state)
      }
      let session = makeSession(
        additionalInstructions: settings.additionalInstructions,
        style: settings.style
      )
      session.prewarm()
      preparedSessionStorage = session
    #else
      throw LocalAIRefinementFailure.providerUnavailable(
        "Apple On-Device is unavailable in this build."
      )
    #endif
  }

  public func refine(
    _ request: LocalAIRefinementRequest,
    settings: LocalAISettings
  ) async throws -> LocalAIRefinementResponse {
    guard #available(macOS 26, *) else {
      throw LocalAIRefinementFailure.providerUnavailable(
        "Apple On-Device requires macOS 26 or later."
      )
    }
    #if canImport(FoundationModels)
      let prompt: LocalAIPrompt
      do {
        prompt = try promptBuilder.build(request)
      } catch LocalAIPromptBuildingError.requestTooLarge {
        throw LocalAIRefinementFailure.requestTooLarge
      } catch {
        throw LocalAIRefinementFailure.generationFailed(
          "The local refinement prompt could not be built."
        )
      }
      let session =
        preparedSessionStorage as? LanguageModelSession
        ?? makeSession(
          additionalInstructions: request.additionalInstructions,
          style: request.style
        )
      preparedSessionStorage = nil
      do {
        let response = try await session.respond(
          to: prompt.prompt,
          generating: AppleRefinementOutput.self,
          options: GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: Self.maximumTokens(
              for: request.transcript
            )
          )
        )
        return LocalAIRefinementResponse(
          text: response.content.text,
          provider: .appleOnDevice,
          modelIdentifier: "Apple SystemLanguageModel"
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw LocalAIRefinementFailure.generationFailed(
          error.localizedDescription
        )
      }
    #else
      throw LocalAIRefinementFailure.providerUnavailable(
        "Apple On-Device is unavailable in this build."
      )
    #endif
  }

  public func release(settings: LocalAISettings) async {
    preparedSessionStorage = nil
  }

  public func shutdown() async {
    preparedSessionStorage = nil
  }

  private func unavailable(
    _ message: String
  ) -> LocalAIProviderReadiness {
    LocalAIProviderReadiness(
      provider: .appleOnDevice,
      state: .unavailable(message)
    )
  }

  private func failure(
    for state: LocalAIReadinessState
  ) -> LocalAIRefinementFailure {
    switch state {
    case .unavailable(let message):
      .providerUnavailable(message)
    case .modelMissing(let model):
      .modelMissing(model)
    case .modelDigestChanged(let expected, let actual):
      .modelDigestChanged(expected: expected, actual: actual)
    case .checking:
      .providerUnavailable("Apple On-Device readiness is still being checked.")
    case .ready:
      .providerUnavailable("Apple On-Device is unavailable.")
    }
  }

  #if canImport(FoundationModels)
    @available(macOS 26, *)
    private func makeSession(
      additionalInstructions: String,
      style: VoiceStyle
    ) -> LanguageModelSession {
      let model = SystemLanguageModel(
        useCase: .general,
        guardrails: .permissiveContentTransformations
      )
      return LanguageModelSession(
        model: model,
        instructions: promptBuilder.instructions(
          additionalInstructions: additionalInstructions,
          style: style
        )
      )
    }

    @available(macOS 26, *)
    private func message(
      for reason:
        SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
      switch reason {
      case .deviceNotEligible:
        "This Mac does not support Apple On-Device generation."
      case .appleIntelligenceNotEnabled:
        "Enable Apple Intelligence to use Apple On-Device generation."
      case .modelNotReady:
        "Apple On-Device model assets are not ready yet."
      @unknown default:
        "Apple On-Device generation is unavailable."
      }
    }
  #endif

  static func maximumTokens(for transcript: String) -> Int {
    min(2_048, max(128, transcript.count / 2 + 128))
  }
}

#if canImport(FoundationModels)
  @available(macOS 26, *)
  @Generable(description: "One polished dictation result.")
  private struct AppleRefinementOutput {
    @Guide(description: "The complete polished text and nothing else.")
    let text: String
  }
#endif
