import Foundation
import Testing

@testable import HardwareControllerCore
@testable import HardwareControllerMac

struct OllamaLocalAIRefinerTests {
  @Test
  func recommendedCatalogPinsTheEvaluatedDigest() throws {
    let entry = try #require(
      OllamaValidatedModelCatalog.entry(named: "qwen3.5:4b")
    )

    #expect(entry.isRecommended)
    #expect(
      entry.digest
        == "2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd"
    )
  }

  @Test
  func readinessRequiresAnInstalledPinnedLocalDigest() async throws {
    let transport = StubOllamaTransport(
      responses: [
        response(#"{"version":"0.12.0"}"#),
        response(
          #"{"models":[{"name":"qwen3.5:4b","size":3400000000,"digest":"digest-4b"}]}"#
        ),
      ]
    )
    let refiner = OllamaLocalAIRefiner(
      baseURL: try loopbackURL(),
      transport: transport
    )
    var settings = LocalAISettings.default
    settings.ollamaModel.expectedDigest = "digest-4b"

    let readiness = await refiner.readiness(
      settings: settings,
      locale: .current
    )

    #expect(readiness.state == .ready)
    #expect(readiness.models.map(\.name) == ["qwen3.5:4b"])
    let requests = await transport.requests
    #expect(requests.map(\.url?.path) == ["/api/version", "/api/tags"])
    #expect(requests.allSatisfy { $0.url?.host == "127.0.0.1" })
  }

  @Test
  func readinessRejectsDigestDrift() async throws {
    let transport = StubOllamaTransport(
      responses: [
        response(#"{"version":"0.12.0"}"#),
        response(
          #"{"models":[{"name":"qwen3.5:4b","size":3400000000,"digest":"changed"}]}"#
        ),
      ]
    )
    let refiner = OllamaLocalAIRefiner(
      baseURL: try loopbackURL(),
      transport: transport
    )
    var settings = LocalAISettings.default
    settings.ollamaModel.expectedDigest = "expected"

    let readiness = await refiner.readiness(
      settings: settings,
      locale: .current
    )

    #expect(
      readiness.state
        == .modelDigestChanged(expected: "expected", actual: "changed")
    )
  }

  @Test
  func refinementUsesStructuredOutputOnFixedLoopback() async throws {
    let transport = StubOllamaTransport(
      responses: [
        response(#"{"version":"0.12.0"}"#),
        response(
          #"{"models":[{"name":"qwen3.5:4b","size":3400000000,"digest":"digest-4b"}]}"#
        ),
        response(#"{"models":[]}"#),
        response(
          #"{"response":"{\"blocks\":[{\"kind\":\"paragraph\",\"items\":[\"Polished text.\"]}]}","done":true,"total_duration":120,"load_duration":20}"#
        ),
      ]
    )
    let refiner = OllamaLocalAIRefiner(
      baseURL: try loopbackURL(),
      transport: transport
    )
    var settings = LocalAISettings.default
    settings.provider = .ollama
    settings.ollamaModel.expectedDigest = "digest-4b"
    settings.modelRetention = .processLifetime

    let output = try await refiner.refine(
      LocalAIRefinementRequest(
        sessionID: UUID(),
        transcript: "um polished text",
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
      ),
      settings: settings
    )

    #expect(output.output == .paragraph("Polished text."))
    #expect(output.modelIdentifier == "qwen3.5:4b@digest-4b")
    let request = try #require(await transport.requests.last)
    let body = try #require(request.httpBody)
    let json = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(json["model"] as? String == "qwen3.5:4b")
    #expect(json["stream"] as? Bool == false)
    #expect(json["think"] as? Bool == false)
    #expect(json["format"] != nil)
    #expect(json["keep_alive"] as? Int == -1)
    let options = try #require(json["options"] as? [String: Any])
    #expect(options["num_ctx"] as? Int == 2_048)
  }

  @Test
  func processLifetimeModelStartedHereIsUnloadedOnRelease() async throws {
    let transport = StubOllamaTransport(
      responses: [
        response(#"{"version":"0.12.0"}"#),
        response(
          #"{"models":[{"name":"qwen3.5:4b","size":3400000000,"digest":"digest-4b"}]}"#
        ),
        response(#"{"models":[]}"#),
        response(#"{"response":"","done":true}"#),
        response(#"{"response":"","done":true}"#),
      ]
    )
    let refiner = OllamaLocalAIRefiner(
      baseURL: try loopbackURL(),
      transport: transport
    )
    var settings = LocalAISettings.default
    settings.provider = .ollama
    settings.ollamaModel.expectedDigest = "digest-4b"
    settings.modelRetention = .processLifetime

    try await refiner.prepare(settings: settings)
    await refiner.release(settings: settings)

    let requests = await transport.requests
    #expect(
      requests.map(\.url?.path)
        == [
          "/api/version", "/api/tags", "/api/ps",
          "/api/generate", "/api/generate",
        ]
    )
    #expect(try keepAlive(in: requests[3]) as? Int == -1)
    #expect(try keepAlive(in: requests[4]) as? Int == 0)
    #expect(requests[4].timeoutInterval == 2)
  }

  @Test
  func preexistingProcessLifetimeModelIsNeverUnloaded() async throws {
    let transport = StubOllamaTransport(
      responses: [
        response(#"{"version":"0.12.0"}"#),
        response(
          #"{"models":[{"name":"qwen3.5:4b","size":3400000000,"digest":"digest-4b"}]}"#
        ),
        response(#"{"models":[{"name":"qwen3.5:4b"}]}"#),
        response(#"{"response":"","done":true}"#),
      ]
    )
    let refiner = OllamaLocalAIRefiner(
      baseURL: try loopbackURL(),
      transport: transport
    )
    var settings = LocalAISettings.default
    settings.provider = .ollama
    settings.ollamaModel.expectedDigest = "digest-4b"
    settings.modelRetention = .processLifetime

    try await refiner.prepare(settings: settings)
    await refiner.release(settings: settings)
    await refiner.shutdown()

    let requests = await transport.requests
    #expect(requests.count == 4)
    #expect(try keepAlive(in: requests[3]) as? Int == -1)
  }

  @Test
  func modelBecomesOwnedAfterThePreexistingInstanceDisappears() async throws {
    let installed =
      #"{"models":[{"name":"qwen3.5:4b","size":3400000000,"digest":"digest-4b"}]}"#
    let transport = StubOllamaTransport(
      responses: [
        response(#"{"version":"0.12.0"}"#),
        response(installed),
        response(#"{"models":[{"name":"qwen3.5:4b"}]}"#),
        response(#"{"response":"","done":true}"#),
        response(#"{"version":"0.12.0"}"#),
        response(installed),
        response(#"{"models":[]}"#),
        response(#"{"response":"","done":true}"#),
        response(#"{"response":"","done":true}"#),
      ]
    )
    let refiner = OllamaLocalAIRefiner(
      baseURL: try loopbackURL(),
      transport: transport
    )
    var settings = LocalAISettings.default
    settings.provider = .ollama
    settings.ollamaModel.expectedDigest = "digest-4b"
    settings.modelRetention = .processLifetime

    try await refiner.prepare(settings: settings)
    try await refiner.prepare(settings: settings)
    await refiner.release(settings: settings)

    let requests = await transport.requests
    let psRequestCount = requests.compactMap { $0.url?.path }
      .filter { $0 == "/api/ps" }.count
    #expect(psRequestCount == 2)
    #expect(try keepAlive(in: requests[8]) as? Int == 0)
  }

  @Test
  func recentUseNeverClaimsOrImmediatelyUnloadsTheModel() async throws {
    let transport = StubOllamaTransport(
      responses: [
        response(#"{"version":"0.12.0"}"#),
        response(
          #"{"models":[{"name":"qwen3.5:4b","size":3400000000,"digest":"digest-4b"}]}"#
        ),
        response(#"{"response":"","done":true}"#),
      ]
    )
    let refiner = OllamaLocalAIRefiner(
      baseURL: try loopbackURL(),
      transport: transport
    )
    var settings = LocalAISettings.default
    settings.provider = .ollama
    settings.ollamaModel.expectedDigest = "digest-4b"

    try await refiner.prepare(settings: settings)
    await refiner.release(settings: settings)
    await refiner.shutdown()

    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(try keepAlive(in: requests[2]) as? String == "5m")
  }

  @Test
  func malformedStructuredOutputIsATypedFailure() async throws {
    let transport = StubOllamaTransport(
      responses: [
        response(#"{"version":"0.12.0"}"#),
        response(
          #"{"models":[{"name":"qwen3.5:4b","size":3400000000,"digest":"digest-4b"}]}"#
        ),
        response(
          #"{"response":"not-json","done":true,"total_duration":120,"load_duration":20}"#
        ),
      ]
    )
    let refiner = OllamaLocalAIRefiner(
      baseURL: try loopbackURL(),
      transport: transport
    )
    var settings = LocalAISettings.default
    settings.ollamaModel.expectedDigest = "digest-4b"

    do {
      _ = try await refiner.refine(request(), settings: settings)
      Issue.record("Expected malformed structured output to fail.")
    } catch let failure as LocalAIRefinementFailure {
      #expect(
        failure
          == .invalidResponse(
            "Ollama returned malformed structured output."
          )
      )
    } catch {
      Issue.record("Expected a typed Local AI refinement failure.")
    }
  }

  @Test
  func transportErrorsBecomeProviderUnavailableFailures() async throws {
    let refiner = OllamaLocalAIRefiner(
      baseURL: try loopbackURL(),
      transport: FailingOllamaTransport()
    )

    do {
      _ = try await refiner.refine(request(), settings: .default)
      Issue.record("Expected the unavailable local provider to fail.")
    } catch let failure as LocalAIRefinementFailure {
      guard case .providerUnavailable = failure else {
        Issue.record("Expected a provider-unavailable failure.")
        return
      }
    } catch {
      Issue.record("Expected a typed Local AI refinement failure.")
    }
  }

  @Test
  func rejectsEveryNonFixedEndpointWithoutSending() async throws {
    let transport = StubOllamaTransport(responses: [])
    let refiner = OllamaLocalAIRefiner(
      baseURL: try #require(URL(string: "http://localhost:11434")),
      transport: transport
    )

    let readiness = await refiner.readiness(
      settings: .default,
      locale: .current
    )

    guard case .unavailable = readiness.state else {
      Issue.record("Expected fixed-loopback rejection.")
      return
    }
    #expect(await transport.requests.isEmpty)
  }

  private func loopbackURL() throws -> URL {
    try #require(URL(string: "http://127.0.0.1:11434"))
  }

  private func response(_ json: String) -> OllamaHTTPResponse {
    OllamaHTTPResponse(statusCode: 200, data: Data(json.utf8))
  }

  private func request() -> LocalAIRefinementRequest {
    LocalAIRefinementRequest(
      sessionID: UUID(),
      transcript: "format this text",
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

  private func keepAlive(in request: URLRequest) throws -> Any? {
    let body = try #require(request.httpBody)
    let json = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    return json["keep_alive"]
  }
}

private actor StubOllamaTransport: OllamaTransporting {
  private var responses: [OllamaHTTPResponse]
  private(set) var requests: [URLRequest] = []

  init(responses: [OllamaHTTPResponse]) {
    self.responses = responses
  }

  func send(_ request: URLRequest) async throws -> OllamaHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else {
      throw LocalAIRefinementFailure.providerUnavailable("No response.")
    }
    return responses.removeFirst()
  }
}

private actor FailingOllamaTransport: OllamaTransporting {
  func send(_ request: URLRequest) async throws -> OllamaHTTPResponse {
    throw URLError(.cannotConnectToHost)
  }
}
