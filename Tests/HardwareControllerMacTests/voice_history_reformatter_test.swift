import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct VoiceHistoryReformatterTest {
  @Test
  func localResponseRetainsStyleAndModelEvidence() async throws {
    let router = HistoryRefinementRouter()
    let reformatter = LocalAIVoiceHistoryReformatter(
      settings: .default,
      refiner: router
    )

    let result = try await reformatter.reformat(
      text: "send the plan",
      sessionID: UUID(),
      style: .formal
    )

    #expect(result.text == "Send the plan.")
    #expect(result.document.style == .formal)
    #expect(result.document.evidence.first?.provider == .appleOnDevice)
    #expect(
      result.document.evidence.first?.modelIdentifier
        == "Apple SystemLanguageModel"
    )
    #expect(await router.preparedStyles == [.formal])
    #expect(await router.requestedStyles == [.formal])
  }

  @Test
  func verbatimSkipsGenerationAndStillBuildsValidatedEvidence()
    async throws
  {
    let router = HistoryRefinementRouter()
    let reformatter = LocalAIVoiceHistoryReformatter(
      settings: .default,
      refiner: router
    )

    let result = try await reformatter.reformat(
      text: "exact words",
      sessionID: UUID(),
      style: .verbatim
    )

    #expect(result.text == "exact words")
    #expect(result.document.style == .verbatim)
    #expect(result.document.evidence.first?.provider == nil)
    #expect(await router.requestedStyles.isEmpty)
  }

  @Test
  func settingsReplacementAndShutdownReleasePrivateModelResources()
    async
  {
    let router = HistoryRefinementRouter()
    let reformatter = LocalAIVoiceHistoryReformatter(
      settings: .default,
      refiner: router
    )
    var replacement = LocalAISettings.default
    replacement.provider = .ollama

    await reformatter.setSettings(replacement)
    await reformatter.shutdown()

    #expect(await router.releasedSettings == [.default])
    #expect(await router.shutdownCount == 1)
  }
}

private actor HistoryRefinementRouter: LocalAIRefinementRouting {
  private(set) var preparedStyles: [VoiceStyle] = []
  private(set) var requestedStyles: [VoiceStyle] = []
  private(set) var releasedSettings: [LocalAISettings] = []
  private(set) var shutdownCount = 0

  func readiness(
    settings: LocalAISettings,
    locale: Locale
  ) async -> LocalAIReadinessSnapshot {
    .checking
  }

  func prepare(settings: LocalAISettings) async throws {
    preparedStyles.append(settings.style)
  }

  func refine(
    _ request: LocalAIRefinementRequest,
    settings: LocalAISettings
  ) async throws -> LocalAIRefinementResponse {
    requestedStyles.append(request.style)
    return LocalAIRefinementResponse(
      text: "Send the plan.",
      provider: .appleOnDevice,
      modelIdentifier: "Apple SystemLanguageModel"
    )
  }

  func release(settings: LocalAISettings) async {
    releasedSettings.append(settings)
  }

  func shutdown() async {
    shutdownCount += 1
  }
}
