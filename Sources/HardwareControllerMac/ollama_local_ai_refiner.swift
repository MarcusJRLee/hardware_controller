import Foundation
import HardwareControllerCore

struct OllamaHTTPResponse: Sendable {
  let statusCode: Int
  let data: Data
}

protocol OllamaTransporting: Sendable {
  func send(_ request: URLRequest) async throws -> OllamaHTTPResponse
}

private final class OllamaRedirectRejectingDelegate:
  NSObject,
  URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

private final class URLSessionOllamaTransport:
  OllamaTransporting,
  @unchecked Sendable
{
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    // Model warm-up may outlive the user-facing three-second refinement gate.
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 15
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.connectionProxyDictionary = [:]
    session = URLSession(
      configuration: configuration,
      delegate: OllamaRedirectRejectingDelegate(),
      delegateQueue: nil
    )
  }

  func send(_ request: URLRequest) async throws -> OllamaHTTPResponse {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw LocalAIRefinementFailure.providerUnavailable(
        "Ollama returned an invalid local response."
      )
    }
    return OllamaHTTPResponse(
      statusCode: response.statusCode,
      data: data
    )
  }
}

public enum OllamaValidatedModelCatalog {
  public struct Entry: Equatable, Sendable {
    public let name: String
    public let digest: String
    public let isRecommended: Bool

    public init(
      name: String,
      digest: String,
      isRecommended: Bool
    ) {
      self.name = name
      self.digest = digest
      self.isRecommended = isRecommended
    }
  }

  public static let entries: [Entry] = [
    Entry(
      name: "qwen3.5:4b",
      digest:
        "2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd",
      isRecommended: true
    )
  ]

  public static func entry(named name: String) -> Entry? {
    entries.first { $0.name == name }
  }
}

public actor OllamaLocalAIRefiner: TranscriptRefining {
  public nonisolated let capability = LocalAIProviderCapability(
    provider: .ollama,
    locality: .fixedLoopback
  )
  private let baseURL: URL
  private let transport: any OllamaTransporting
  private let promptBuilder: VersionedLocalAIPromptBuilder
  private var ownedProcessLifetimeModels: Set<String> = []
  private var preexistingProcessLifetimeModels: Set<String> = []

  public init() {
    baseURL = Self.loopbackBaseURL
    transport = URLSessionOllamaTransport()
    promptBuilder = VersionedLocalAIPromptBuilder()
  }

  init(
    baseURL: URL,
    transport: any OllamaTransporting,
    promptBuilder: VersionedLocalAIPromptBuilder =
      VersionedLocalAIPromptBuilder()
  ) {
    self.baseURL = baseURL
    self.transport = transport
    self.promptBuilder = promptBuilder
  }

  public func readiness(
    settings: LocalAISettings,
    locale: Locale
  ) async -> LocalAIProviderReadiness {
    guard Self.isFixedLoopback(baseURL) else {
      return unavailable(
        "Ollama must use the fixed local loopback endpoint."
      )
    }
    do {
      let version: OllamaVersionResponse = try await get(
        path: "api/version"
      )
      guard !version.version.isEmpty else {
        return unavailable("Ollama did not report a local version.")
      }
      let tags: OllamaTagsResponse = try await get(path: "api/tags")
      let models = installedModels(from: tags.models)
      guard
        let selected = models.first(where: {
          $0.name == settings.ollamaModel.name
        })
      else {
        return LocalAIProviderReadiness(
          provider: .ollama,
          state: .modelMissing(settings.ollamaModel.name),
          models: models
        )
      }
      guard
        let expectedDigest = expectedDigest(
          for: settings.ollamaModel
        )
      else {
        return LocalAIProviderReadiness(
          provider: .ollama,
          state: .unavailable(
            "Select the installed model again to pin its local digest."
          ),
          models: models
        )
      }
      guard selected.digest == expectedDigest else {
        return LocalAIProviderReadiness(
          provider: .ollama,
          state: .modelDigestChanged(
            expected: expectedDigest,
            actual: selected.digest
          ),
          models: models
        )
      }
      return LocalAIProviderReadiness(
        provider: .ollama,
        state: .ready,
        models: models
      )
    } catch {
      return unavailable(
        "Ollama is not ready on this Mac. Start Ollama and try again."
      )
    }
  }

  public func prepare(settings: LocalAISettings) async throws {
    let selected = try await validatedModel(settings: settings)
    let claimsOwnership = try await shouldClaimModelOwnership(
      selected.name,
      settings: settings
    )
    let request = OllamaGenerateRequest(
      model: selected.name,
      prompt: "",
      system: nil,
      stream: false,
      think: nil,
      format: nil,
      options: Self.deterministicOptions,
      keepAlive: keepAlive(for: settings.modelRetention)
    )
    let _: OllamaGenerateResponse = try await post(
      path: "api/generate",
      body: request
    )
    if claimsOwnership {
      ownedProcessLifetimeModels.insert(selected.name)
    }
  }

  public func refine(
    _ request: LocalAIRefinementRequest,
    settings: LocalAISettings
  ) async throws -> LocalAIRefinementResponse {
    let selected = try await validatedModel(settings: settings)
    let claimsOwnership = try await shouldClaimModelOwnership(
      selected.name,
      settings: settings
    )
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
    let response: OllamaGenerateResponse = try await post(
      path: "api/generate",
      body: OllamaGenerateRequest(
        model: selected.name,
        prompt: prompt.prompt,
        system: prompt.instructions,
        stream: false,
        think: false,
        format: .voiceBlocks,
        options: Self.deterministicOptions,
        keepAlive: keepAlive(for: settings.modelRetention)
      )
    )
    if claimsOwnership {
      ownedProcessLifetimeModels.insert(selected.name)
    }
    guard response.done else {
      throw LocalAIRefinementFailure.invalidResponse(
        "Ollama did not finish the local response."
      )
    }
    guard let data = response.response.data(using: .utf8) else {
      throw LocalAIRefinementFailure.invalidResponse(
        "Ollama returned text with an invalid encoding."
      )
    }
    let content: VoiceFormattingDraft
    do {
      content = try JSONDecoder().decode(
        VoiceFormattingDraft.self,
        from: data
      )
    } catch {
      throw LocalAIRefinementFailure.invalidResponse(
        "Ollama returned malformed structured output."
      )
    }
    return LocalAIRefinementResponse(
      output: content,
      provider: .ollama,
      modelIdentifier: "\(selected.name)@\(selected.digest)",
      modelLoadNanoseconds: response.loadDuration,
      generationNanoseconds: response.totalDuration,
      generatedTokenCount: response.evaluationCount,
      tokenGenerationNanoseconds: response.evaluationDuration
    )
  }

  public func release(settings: LocalAISettings) async {
    guard settings.modelRetention == .processLifetime else {
      return
    }
    let model = settings.ollamaModel.name
    preexistingProcessLifetimeModels.remove(model)
    guard ownedProcessLifetimeModels.contains(model) else {
      return
    }
    do {
      try await unload(model)
      ownedProcessLifetimeModels.remove(model)
    } catch {
      return
    }
  }

  public func shutdown() async {
    preexistingProcessLifetimeModels.removeAll()
    for model in ownedProcessLifetimeModels.sorted() {
      do {
        try await unload(model)
        ownedProcessLifetimeModels.remove(model)
      } catch {
        continue
      }
    }
  }

  private func validatedModel(
    settings: LocalAISettings
  ) async throws -> LocalAIInstalledModel {
    let result = await readiness(settings: settings, locale: .current)
    guard result.state.canRun else {
      throw failure(for: result.state)
    }
    guard
      let model = result.models.first(where: {
        $0.name == settings.ollamaModel.name
      })
    else {
      throw LocalAIRefinementFailure.modelMissing(
        settings.ollamaModel.name
      )
    }
    return model
  }

  private func expectedDigest(
    for selection: LocalAIModelSelection
  ) -> String? {
    selection.expectedDigest
      ?? OllamaValidatedModelCatalog.entry(named: selection.name)?.digest
  }

  /// Claims only models absent before this client's indefinite-retention request.
  private func shouldClaimModelOwnership(
    _ model: String,
    settings: LocalAISettings
  ) async throws -> Bool {
    guard settings.modelRetention == .processLifetime else {
      return false
    }
    if ownedProcessLifetimeModels.contains(model) {
      return false
    }
    let running: OllamaRunningModelsResponse = try await get(path: "api/ps")
    if running.models.contains(where: { $0.name == model }) {
      preexistingProcessLifetimeModels.insert(model)
      return false
    }
    preexistingProcessLifetimeModels.remove(model)
    return true
  }

  private func unload(_ model: String) async throws {
    let request = OllamaGenerateRequest(
      model: model,
      prompt: "",
      system: nil,
      stream: false,
      think: nil,
      format: nil,
      options: nil,
      keepAlive: .unload
    )
    let _: OllamaGenerateResponse = try await post(
      path: "api/generate",
      body: request,
      timeoutInterval: 2
    )
  }

  private func installedModels(
    from models: [OllamaModelResponse]
  ) -> [LocalAIInstalledModel] {
    models.compactMap { model in
      guard
        model.size > 0,
        !model.digest.isEmpty,
        !model.name.lowercased().hasSuffix(":cloud")
      else {
        return nil
      }
      let catalog = OllamaValidatedModelCatalog.entry(named: model.name)
      let validated = catalog?.digest == model.digest
      return LocalAIInstalledModel(
        name: model.name,
        digest: model.digest,
        sizeBytes: model.size,
        isValidated: validated,
        isRecommended: validated && catalog?.isRecommended == true
      )
    }
    .sorted {
      if $0.isRecommended != $1.isRecommended {
        return $0.isRecommended
      }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private func get<Response: Decodable & Sendable>(
    path: String
  ) async throws -> Response {
    try await send(path: path, method: "GET", body: Optional<Data>.none)
  }

  private func post<Body: Encodable, Response: Decodable & Sendable>(
    path: String,
    body: Body,
    timeoutInterval: TimeInterval = 15
  ) async throws -> Response {
    let data: Data
    do {
      data = try JSONEncoder().encode(body)
    } catch {
      throw LocalAIRefinementFailure.generationFailed(
        "The local Ollama request could not be encoded."
      )
    }
    return try await send(
      path: path,
      method: "POST",
      body: data,
      timeoutInterval: timeoutInterval
    )
  }

  private func send<Response: Decodable & Sendable>(
    path: String,
    method: String,
    body: Data?,
    timeoutInterval: TimeInterval = 15
  ) async throws -> Response {
    let url = baseURL.appendingPathComponent(path)
    guard Self.isFixedLoopback(url) else {
      throw LocalAIRefinementFailure.providerUnavailable(
        "Ollama requests are restricted to fixed local loopback access."
      )
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = timeoutInterval
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil {
      request.setValue(
        "application/json",
        forHTTPHeaderField: "Content-Type"
      )
    }
    let response: OllamaHTTPResponse
    do {
      response = try await transport.send(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw LocalAIRefinementFailure.providerUnavailable(
        "Ollama did not respond on the fixed local endpoint."
      )
    }
    guard (200..<300).contains(response.statusCode) else {
      throw LocalAIRefinementFailure.generationFailed(
        "Ollama returned local HTTP status \(response.statusCode)."
      )
    }
    do {
      return try JSONDecoder().decode(Response.self, from: response.data)
    } catch {
      throw LocalAIRefinementFailure.invalidResponse(
        "Ollama returned an invalid local response."
      )
    }
  }

  private func failure(
    for state: LocalAIReadinessState
  ) -> LocalAIRefinementFailure {
    switch state {
    case .checking:
      .providerUnavailable("Ollama readiness is still being checked.")
    case .ready:
      .providerUnavailable("Ollama is unavailable.")
    case .unavailable(let message):
      .providerUnavailable(message)
    case .modelMissing(let model):
      .modelMissing(model)
    case .modelDigestChanged(let expected, let actual):
      .modelDigestChanged(expected: expected, actual: actual)
    }
  }

  private func unavailable(
    _ message: String
  ) -> LocalAIProviderReadiness {
    LocalAIProviderReadiness(
      provider: .ollama,
      state: .unavailable(message)
    )
  }

  private func keepAlive(
    for retention: LocalAIModelRetention
  ) -> OllamaKeepAlive {
    retention == .processLifetime ? .indefinitely : .duration("5m")
  }

  private static let deterministicOptions = OllamaGenerationOptions(
    temperature: 0,
    contextWindow: 2_048
  )

  private static let loopbackBaseURL: URL = {
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = 11_434
    return components.url
      ?? URL(fileURLWithPath: "/invalid-ollama-loopback-url")
  }()

  private static func isFixedLoopback(_ url: URL) -> Bool {
    url.scheme == "http"
      && url.host == "127.0.0.1"
      && url.port == 11_434
      && url.user == nil
      && url.password == nil
  }
}

private struct OllamaVersionResponse: Decodable, Sendable {
  let version: String
}

private struct OllamaTagsResponse: Decodable, Sendable {
  let models: [OllamaModelResponse]
}

private struct OllamaModelResponse: Decodable, Sendable {
  let name: String
  let size: UInt64
  let digest: String
}

private struct OllamaGenerationOptions: Encodable {
  let temperature: Int
  let contextWindow: Int

  enum CodingKeys: String, CodingKey {
    case temperature
    case contextWindow = "num_ctx"
  }
}

private struct OllamaStringSchema: Encodable {
  let type: String
  let allowedValues: [String]?

  enum CodingKeys: String, CodingKey {
    case type
    case allowedValues = "enum"
  }
}

private struct OllamaStringArraySchema: Encodable {
  let type: String
  let items: OllamaStringSchema
  let minimumItems: Int

  enum CodingKeys: String, CodingKey {
    case type
    case items
    case minimumItems = "minItems"
  }
}

private struct OllamaBlockProperties: Encodable {
  let kind: OllamaStringSchema
  let items: OllamaStringArraySchema
}

private struct OllamaBlockSchema: Encodable {
  let type: String
  let properties: OllamaBlockProperties
  let required: [String]
  let additionalProperties: Bool
}

private struct OllamaBlockArraySchema: Encodable {
  let type: String
  let items: OllamaBlockSchema
  let minimumItems: Int

  enum CodingKeys: String, CodingKey {
    case type
    case items
    case minimumItems = "minItems"
  }
}

private struct OllamaRootProperties: Encodable {
  let blocks: OllamaBlockArraySchema
}

private struct OllamaOutputFormat: Encodable {
  let type: String
  let properties: OllamaRootProperties
  let required: [String]
  let additionalProperties: Bool

  static let voiceBlocks = OllamaOutputFormat(
    type: "object",
    properties: OllamaRootProperties(
      blocks: OllamaBlockArraySchema(
        type: "array",
        items: OllamaBlockSchema(
          type: "object",
          properties: OllamaBlockProperties(
            kind: OllamaStringSchema(
              type: "string",
              allowedValues: [
                "paragraph",
                "unorderedList",
                "orderedList",
              ]
            ),
            items: OllamaStringArraySchema(
              type: "array",
              items: OllamaStringSchema(
                type: "string",
                allowedValues: nil
              ),
              minimumItems: 1
            )
          ),
          required: ["kind", "items"],
          additionalProperties: false
        ),
        minimumItems: 1
      )
    ),
    required: ["blocks"],
    additionalProperties: false
  )
}

private struct OllamaGenerateRequest: Encodable {
  let model: String
  let prompt: String
  let system: String?
  let stream: Bool
  let think: Bool?
  let format: OllamaOutputFormat?
  let options: OllamaGenerationOptions?
  let keepAlive: OllamaKeepAlive

  enum CodingKeys: String, CodingKey {
    case model
    case prompt
    case system
    case stream
    case think
    case format
    case options
    case keepAlive = "keep_alive"
  }
}

private enum OllamaKeepAlive: Encodable {
  case duration(String)
  case indefinitely
  case unload

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .duration(let duration):
      try container.encode(duration)
    case .indefinitely:
      try container.encode(-1)
    case .unload:
      try container.encode(0)
    }
  }
}

private struct OllamaRunningModelsResponse: Decodable, Sendable {
  let models: [OllamaRunningModelResponse]
}

private struct OllamaRunningModelResponse: Decodable, Sendable {
  let name: String
}

private struct OllamaGenerateResponse: Decodable, Sendable {
  let response: String
  let done: Bool
  let totalDuration: UInt64?
  let loadDuration: UInt64?
  let evaluationCount: Int?
  let evaluationDuration: UInt64?

  enum CodingKeys: String, CodingKey {
    case response
    case done
    case totalDuration = "total_duration"
    case loadDuration = "load_duration"
    case evaluationCount = "eval_count"
    case evaluationDuration = "eval_duration"
  }
}
