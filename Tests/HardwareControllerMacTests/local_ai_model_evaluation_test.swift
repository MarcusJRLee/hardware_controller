import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct LocalAIModelEvaluationTest {
  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_RUN_LOCAL_AI_MODEL_EVALUATION"
        ] == "1"
    )
  )
  func evaluatesApprovedLocalProvidersAgainstTheFixedCorpus() async throws {
    let candidates = [
      EvaluationCandidate(
        provider: .ollama,
        name: "qwen3.5:4b",
        digest:
          "2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd"
      ),
      EvaluationCandidate(
        provider: .ollama,
        name: "qwen3.5:9b",
        digest:
          "6488c96fa5faab64bb65cbd30d4289e20e6130ef535a93ef9a49f42eda893ea7"
      ),
      EvaluationCandidate(
        provider: .appleOnDevice,
        name: "Apple SystemLanguageModel",
        digest: nil
      ),
    ]
    let selectedModel = ProcessInfo.processInfo.environment[
      "HC_LOCAL_AI_EVALUATION_MODEL"
    ]

    for candidate in candidates
    where selectedModel == nil || selectedModel == candidate.name {
      let report = await evaluate(candidate)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(report)
      let json = try #require(String(data: data, encoding: .utf8))
      print("LOCAL_AI_EVALUATION_REPORT\n\(json)")
      if report.availabilityFailure == nil {
        #expect(report.semanticGateFailures.isEmpty)
      }
    }
  }

  private func evaluate(
    _ candidate: EvaluationCandidate
  ) async -> EvaluationReport {
    let settings = LocalAISettings(
      provider: candidate.provider,
      ollamaModel: LocalAIModelSelection(
        name: candidate.name,
        expectedDigest: candidate.digest
      ),
      modelRetention: .processLifetime
    )
    let coldPreparationLatency: EvaluationLatency
    do {
      coldPreparationLatency = try await measureFreshPreparation(
        candidate,
        settings: settings
      )
    } catch {
      return EvaluationReport.unavailable(
        candidate: candidate,
        reason: String(describing: error)
      )
    }
    let refiner = makeRefiner(candidate)
    let readiness = await refiner.readiness(
      settings: settings,
      locale: Locale(identifier: "en_US")
    )
    guard readiness.state.canRun else {
      return EvaluationReport.unavailable(
        candidate: candidate,
        reason: String(describing: readiness.state)
      )
    }

    let prepareStart = MonotonicClock.nowNanoseconds()
    do {
      try await refiner.prepare(settings: settings)
    } catch {
      return EvaluationReport.unavailable(
        candidate: candidate,
        reason: String(describing: error)
      )
    }
    let prepareNanoseconds = elapsed(since: prepareStart)

    let applier = PersonalDictionaryReplacementApplier()
    let validator = RefinedTranscriptValidator()
    let polisher = VoiceFormattingDraftPolisher()
    let normalizer = VoiceFormattingDraftNormalizer()
    let casingTransformer = VoiceCasingTransformer()
    let builder = VoiceFormattedDocumentBuilder()
    let renderer = VoiceFormattedTextRenderer()
    var outcomes: [EvaluationOutcome] = []
    var latencies: [UInt64] = []
    var modelLoadNanoseconds: [UInt64] = []
    var generatedTokens = 0
    var tokenGenerationNanoseconds: UInt64 = 0

    for evaluationCase in LocalAIEvaluationCorpus.cases {
      let source = applier.apply(
        evaluationCase.dictionary,
        to: evaluationCase.transcript
      )
      let request = LocalAIRefinementRequest(
        sessionID: UUID(),
        transcript: source,
        context: LocalAITargetContext(
          localeIdentifier:
            evaluationCase.category == "multilingual"
            ? "es_ES" : "en_US",
          profileName: "Evaluation",
          applicationName: "Evaluation Target",
          applicationBundleIdentifier: "local.evaluation",
          targetRole: "AXTextArea",
          supportsMultilineText: evaluationCase.supportsMultiline,
          nearbyText: evaluationCase.nearbyText
        ),
        dictionary: evaluationCase.dictionary,
        additionalInstructions: evaluationCase.additionalInstructions,
        casingPolicy: evaluationCase.casingPolicy
      )
      let start = MonotonicClock.nowNanoseconds()
      do {
        let response = try await refiner.refine(
          request,
          settings: settings
        )
        let latency = elapsed(since: start)
        latencies.append(latency)
        if let load = response.modelLoadNanoseconds {
          modelLoadNanoseconds.append(load)
        }
        generatedTokens += response.generatedTokenCount ?? 0
        tokenGenerationNanoseconds +=
          response.tokenGenerationNanoseconds ?? 0

        let normalized = normalizer.normalize(
          response.output,
          transcript: source,
          intent: request.listIntent
        )
        let polished = polisher.polish(
          normalized,
          preserving: source,
          style: request.style
        )
        let cased = casingTransformer.apply(
          request.casingPolicy,
          to: polished,
          preserving: source,
          dictionary: request.dictionary
        )
        let document = try builder.build(
          output: cased,
          rawText: source,
          style: request.style,
          provider: response.provider,
          modelIdentifier: response.modelIdentifier,
          promptRevision: VersionedLocalAIPromptBuilder.currentRevision
        )
        let output = try renderer.render(
          document,
          supportsMultiline: evaluationCase.supportsMultiline
        )
        var failureKinds: Set<LocalAIEvaluationFailureKind> = []
        var semanticFailure: String?
        let actualBlockKinds = Set(cased.blocks.map(\.kind))
        if !evaluationCase.requiredBlockKinds.isSubset(
          of: actualBlockKinds
        ) {
          failureKinds.insert(.structure)
        }
        let expectedCasing = casingTransformer.apply(
          request.casingPolicy,
          to: cased,
          preserving: source,
          dictionary: request.dictionary
        )
        if expectedCasing != cased {
          failureKinds.insert(.casing)
        }
        if evaluationCase.protectedTokens.contains(where: {
          !output.contains($0)
        }) {
          failureKinds.insert(.protectedToken)
        }
        do {
          _ = try validator.validate(
            output,
            preserving: source,
            dictionary: evaluationCase.dictionary,
            supportsMultiline: evaluationCase.supportsMultiline,
            context: request.context
          )
          semanticFailure = nil
        } catch {
          semanticFailure = String(describing: error)
          failureKinds.insert(.semantic)
        }
        outcomes.append(
          EvaluationOutcome(
            id: evaluationCase.id,
            output: output,
            exactQualityPass: evaluationCase.acceptedOutputs.contains(
              output
            ),
            failureKinds: failureKinds.sorted {
              $0.rawValue < $1.rawValue
            },
            semanticFailure: semanticFailure,
            latencyNanoseconds: latency,
            error: nil
          )
        )
      } catch {
        let latency = elapsed(since: start)
        latencies.append(latency)
        outcomes.append(
          EvaluationOutcome(
            id: evaluationCase.id,
            output: nil,
            exactQualityPass: false,
            failureKinds: [],
            semanticFailure: nil,
            latencyNanoseconds: latency,
            error: String(describing: error)
          )
        )
      }
    }

    let residentBytes =
      candidate.provider == .ollama
      ? await ollamaResidentBytes(model: candidate.name) : nil
    let gateInputs = outcomes.map {
      LocalAIEvaluationGateInput(
        failures: Set($0.failureKinds),
        providerError: $0.error != nil
      )
    }
    let report = EvaluationReport(
      provider: candidate.provider.rawValue,
      model: candidate.name,
      digest: candidate.digest,
      availabilityFailure: nil,
      corpusCount: outcomes.count,
      exactQualityPasses: outcomes.filter(\.exactQualityPass).count,
      semanticCorruptions: outcomes.filter {
        !$0.failureKinds.isEmpty
      }.count,
      timeoutOrErrorCount: outcomes.filter { $0.error != nil }.count,
      semanticGateFailures:
        LocalAIEvaluationSemanticGate().failures(for: gateInputs),
      coldPreparationLatency: coldPreparationLatency,
      prepareNanoseconds: prepareNanoseconds,
      latency: EvaluationLatency(latencies),
      maximumReportedModelLoadNanoseconds:
        modelLoadNanoseconds.max(),
      generatedTokenCount: generatedTokens,
      tokenGenerationNanoseconds:
        tokenGenerationNanoseconds == 0
        ? nil : tokenGenerationNanoseconds,
      tokensPerSecond:
        tokenGenerationNanoseconds == 0
        ? nil
        : Double(generatedTokens) * 1_000_000_000
          / Double(tokenGenerationNanoseconds),
      residentModelBytes: residentBytes,
      outcomes: outcomes
    )
    await refiner.shutdown()
    return report
  }

  private func measureFreshPreparation(
    _ candidate: EvaluationCandidate,
    settings: LocalAISettings
  ) async throws -> EvaluationLatency {
    if candidate.provider == .ollama {
      guard await waitUntilOllamaUnloaded(model: candidate.name) else {
        throw LocalAIRefinementFailure.providerUnavailable(
          "Cold evaluation requires \(candidate.name) to be unloaded."
        )
      }
    }
    var samples: [UInt64] = []
    for _ in 0..<5 {
      let refiner = makeRefiner(candidate)
      let readiness = await refiner.readiness(
        settings: settings,
        locale: Locale(identifier: "en_US")
      )
      guard readiness.state.canRun else {
        throw LocalAIRefinementFailure.providerUnavailable(
          String(describing: readiness.state)
        )
      }
      let start = MonotonicClock.nowNanoseconds()
      do {
        try await refiner.prepare(settings: settings)
      } catch {
        await refiner.shutdown()
        throw error
      }
      samples.append(elapsed(since: start))
      await refiner.shutdown()
      if candidate.provider == .ollama {
        guard await waitUntilOllamaUnloaded(model: candidate.name) else {
          throw LocalAIRefinementFailure.generationFailed(
            "Ollama did not unload \(candidate.name) between cold samples."
          )
        }
      }
    }
    guard let latency = EvaluationLatency(samples) else {
      throw LocalAIRefinementFailure.generationFailed(
        "Cold preparation produced no samples."
      )
    }
    return latency
  }

  private func makeRefiner(
    _ candidate: EvaluationCandidate
  ) -> any TranscriptRefining {
    candidate.provider == .ollama
      ? OllamaLocalAIRefiner()
      : AppleFoundationModelRefiner()
  }

  private func waitUntilOllamaUnloaded(
    model: String
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while clock.now < deadline {
      if await ollamaResidentBytes(model: model) == nil {
        return true
      }
      do {
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        return false
      }
    }
    return false
  }

  private func ollamaResidentBytes(model: String) async -> UInt64? {
    guard let url = URL(string: "http://127.0.0.1:11434/api/ps") else {
      return nil
    }
    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      guard
        let response = response as? HTTPURLResponse,
        response.statusCode == 200
      else {
        return nil
      }
      let running = try JSONDecoder().decode(
        OllamaRunningModels.self,
        from: data
      )
      return running.models.first { $0.name == model }?.sizeVRAM
    } catch {
      return nil
    }
  }

  private func elapsed(since start: UInt64) -> UInt64 {
    let now = MonotonicClock.nowNanoseconds()
    return now >= start ? now - start : 0
  }
}

private struct EvaluationCandidate: Sendable {
  let provider: LocalAIProviderKind
  let name: String
  let digest: String?
}

private struct EvaluationReport: Codable {
  let provider: String
  let model: String
  let digest: String?
  let availabilityFailure: String?
  let corpusCount: Int
  let exactQualityPasses: Int
  let semanticCorruptions: Int
  let timeoutOrErrorCount: Int
  let semanticGateFailures: [String]
  let coldPreparationLatency: EvaluationLatency?
  let prepareNanoseconds: UInt64?
  let latency: EvaluationLatency?
  let maximumReportedModelLoadNanoseconds: UInt64?
  let generatedTokenCount: Int
  let tokenGenerationNanoseconds: UInt64?
  let tokensPerSecond: Double?
  let residentModelBytes: UInt64?
  let outcomes: [EvaluationOutcome]

  static func unavailable(
    candidate: EvaluationCandidate,
    reason: String
  ) -> EvaluationReport {
    EvaluationReport(
      provider: candidate.provider.rawValue,
      model: candidate.name,
      digest: candidate.digest,
      availabilityFailure: reason,
      corpusCount: 0,
      exactQualityPasses: 0,
      semanticCorruptions: 0,
      timeoutOrErrorCount: 0,
      semanticGateFailures: [],
      coldPreparationLatency: nil,
      prepareNanoseconds: nil,
      latency: nil,
      maximumReportedModelLoadNanoseconds: nil,
      generatedTokenCount: 0,
      tokenGenerationNanoseconds: nil,
      tokensPerSecond: nil,
      residentModelBytes: nil,
      outcomes: []
    )
  }
}

private struct EvaluationOutcome: Codable {
  let id: String
  let output: String?
  let exactQualityPass: Bool
  let failureKinds: [LocalAIEvaluationFailureKind]
  let semanticFailure: String?
  let latencyNanoseconds: UInt64
  let error: String?
}

private struct EvaluationLatency: Codable {
  let sampleCount: Int
  let p50Nanoseconds: UInt64
  let p95Nanoseconds: UInt64
  let p99Nanoseconds: UInt64
  let maximumNanoseconds: UInt64

  init?(_ samples: [UInt64]) {
    let sorted = samples.sorted()
    guard let maximum = sorted.last else {
      return nil
    }
    sampleCount = sorted.count
    p50Nanoseconds = Self.percentile(0.50, sorted: sorted)
    p95Nanoseconds = Self.percentile(0.95, sorted: sorted)
    p99Nanoseconds = Self.percentile(0.99, sorted: sorted)
    maximumNanoseconds = maximum
  }

  private static func percentile(
    _ percentile: Double,
    sorted: [UInt64]
  ) -> UInt64 {
    let rank = Int(ceil(percentile * Double(sorted.count))) - 1
    return sorted[max(0, min(rank, sorted.count - 1))]
  }
}

private struct OllamaRunningModels: Decodable {
  let models: [OllamaRunningModel]
}

private struct OllamaRunningModel: Decodable {
  let name: String
  let sizeVRAM: UInt64

  enum CodingKeys: String, CodingKey {
    case name
    case sizeVRAM = "size_vram"
  }
}
