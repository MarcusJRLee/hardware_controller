import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct LocalAIRefinementRouterTest {
  @Test
  func queriesBothProvidersAndRoutesSelectedLifecycle() async throws {
    let apple = RouterRecordingRefiner(provider: .appleOnDevice)
    let ollama = RouterRecordingRefiner(provider: .ollama)
    let router = LocalAIRefinementRouter(
      apple: apple,
      ollama: ollama
    )
    var settings = LocalAISettings.default
    settings.provider = .ollama

    let readiness = await router.readiness(
      settings: settings,
      locale: Locale(identifier: "en_US")
    )
    try await router.prepare(settings: settings)
    let response = try await router.refine(
      request(),
      settings: settings
    )
    await router.release(settings: settings)
    await router.shutdown()

    #expect(readiness.apple.provider == .appleOnDevice)
    #expect(readiness.ollama.provider == .ollama)
    #expect(response.provider == .ollama)
    #expect(
      await apple.snapshot()
        == RouterRefinerSnapshot(
          readinessCount: 1,
          preparationCount: 0,
          refinementCount: 0,
          releaseCount: 0,
          shutdownCount: 1
        ))
    #expect(
      await ollama.snapshot()
        == RouterRefinerSnapshot(
          readinessCount: 1,
          preparationCount: 1,
          refinementCount: 1,
          releaseCount: 1,
          shutdownCount: 1
        ))
  }

  @Test
  func rejectsRemoteCapableProviderBeforeAnyAdapterCall() async {
    let apple = RouterRecordingRefiner(provider: .appleOnDevice)
    let remote = RouterRecordingRefiner(
      provider: .ollama,
      locality: .remoteCapable
    )
    let router = LocalAIRefinementRouter(
      apple: apple,
      ollama: remote
    )
    var settings = LocalAISettings.default
    settings.provider = .ollama

    let readiness = await router.readiness(
      settings: settings,
      locale: Locale(identifier: "en_US")
    )
    await #expect(
      throws: LocalAIRefinementFailure.remoteProviderRejected
    ) {
      try await router.prepare(settings: settings)
    }
    await #expect(
      throws: LocalAIRefinementFailure.remoteProviderRejected
    ) {
      try await router.refine(request(), settings: settings)
    }
    await router.release(settings: settings)
    await router.shutdown()

    guard case .unavailable = readiness.ollama.state else {
      Issue.record("Remote-capable readiness must fail closed.")
      return
    }
    #expect(
      await remote.snapshot()
        == RouterRefinerSnapshot()
    )
  }

  @Test
  func rejectsDeclaredProviderIdentityMismatchBeforeAdapterCall() async {
    let mismatchedApple = RouterRecordingRefiner(provider: .ollama)
    let ollama = RouterRecordingRefiner(provider: .ollama)
    let router = LocalAIRefinementRouter(
      apple: mismatchedApple,
      ollama: ollama
    )
    let settings = LocalAISettings.default

    let readiness = await router.readiness(
      settings: settings,
      locale: Locale(identifier: "en_US")
    )
    await #expect(
      throws: LocalAIRefinementFailure.providerUnavailable(
        "The selected provider declared mismatched identity evidence."
      )
    ) {
      try await router.prepare(settings: settings)
    }

    guard case .unavailable = readiness.apple.state else {
      Issue.record("Mismatched provider identity must fail closed.")
      return
    }
    #expect(await mismatchedApple.snapshot() == RouterRefinerSnapshot())
  }

  @Test
  func rejectsMismatchedProviderIdentityInGeneratedResponse() async {
    let apple = RouterRecordingRefiner(
      provider: .appleOnDevice,
      responseProvider: .ollama
    )
    let ollama = RouterRecordingRefiner(provider: .ollama)
    let router = LocalAIRefinementRouter(
      apple: apple,
      ollama: ollama
    )
    let settings = LocalAISettings.default

    await #expect(
      throws: LocalAIRefinementFailure.providerUnavailable(
        "The selected provider returned mismatched identity evidence."
      )
    ) {
      try await router.refine(request(), settings: settings)
    }

    #expect(await apple.snapshot().refinementCount == 1)
  }

  private func request() -> LocalAIRefinementRequest {
    LocalAIRefinementRequest(
      sessionID: UUID(),
      transcript: "test text",
      context: LocalAITargetContext(
        localeIdentifier: "en_US",
        profileName: "Coding",
        applicationName: "Notes",
        applicationBundleIdentifier: "com.apple.Notes",
        targetRole: "AXTextArea",
        supportsMultilineText: true,
        nearbyText: nil
      ),
      dictionary: .empty,
      additionalInstructions: ""
    )
  }
}

private struct RouterRefinerSnapshot: Equatable {
  var readinessCount = 0
  var preparationCount = 0
  var refinementCount = 0
  var releaseCount = 0
  var shutdownCount = 0
}

private actor RouterRecordingRefiner: TranscriptRefining {
  nonisolated let capability: LocalAIProviderCapability
  nonisolated let responseProvider: LocalAIProviderKind
  private var state = RouterRefinerSnapshot()

  init(
    provider: LocalAIProviderKind,
    locality: LocalAIProviderLocality = .inProcess,
    responseProvider: LocalAIProviderKind? = nil
  ) {
    capability = LocalAIProviderCapability(
      provider: provider,
      locality: locality
    )
    self.responseProvider = responseProvider ?? provider
  }

  func readiness(
    settings: LocalAISettings,
    locale: Locale
  ) -> LocalAIProviderReadiness {
    state.readinessCount += 1
    return LocalAIProviderReadiness(
      provider: capability.provider,
      state: .ready
    )
  }

  func prepare(settings: LocalAISettings) {
    state.preparationCount += 1
  }

  func refine(
    _ request: LocalAIRefinementRequest,
    settings: LocalAISettings
  ) -> LocalAIRefinementResponse {
    state.refinementCount += 1
    return LocalAIRefinementResponse(
      text: request.transcript,
      provider: responseProvider,
      modelIdentifier: "test-model"
    )
  }

  func release(settings: LocalAISettings) {
    state.releaseCount += 1
  }

  func shutdown() {
    state.shutdownCount += 1
  }

  func snapshot() -> RouterRefinerSnapshot {
    state
  }
}
