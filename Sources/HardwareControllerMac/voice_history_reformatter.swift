import Foundation
import HardwareControllerCore

/// Applies the selected local formatter to one immutable History source result.
public actor LocalAIVoiceHistoryReformatter:
  VoiceHistoryReformatting
{
  private let refiner: any LocalAIRefinementRouting
  private let validator = RefinedTranscriptValidator()
  private let builder = VoiceFormattedDocumentBuilder()
  private let renderer = VoiceFormattedTextRenderer()
  private let casingTransformer = VoiceCasingTransformer()
  private var settings: LocalAISettings
  private var operationInProgress = false
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    settings: LocalAISettings,
    refiner: any LocalAIRefinementRouting = LocalAIRefinementRouter()
  ) {
    self.settings = settings
    self.refiner = refiner
  }

  public func setSettings(_ settings: LocalAISettings) async {
    await acquireOperation()
    defer { releaseOperation() }
    guard self.settings != settings else {
      return
    }
    let previous = self.settings
    self.settings = settings
    await refiner.release(settings: previous)
  }

  public func shutdown() async {
    await acquireOperation()
    defer { releaseOperation() }
    await refiner.shutdown()
  }

  public func reformat(
    text: String,
    sessionID: UUID,
    style: VoiceStyle
  ) async throws -> VoiceHistoryReformat {
    await acquireOperation()
    defer { releaseOperation() }
    var selectedSettings = settings
    selectedSettings.style = style
    try selectedSettings.validate()
    let context = LocalAITargetContext(
      localeIdentifier: Locale.current.identifier,
      profileName: "Voice History",
      applicationName: "Voice History",
      applicationBundleIdentifier: nil,
      targetRole: nil,
      supportsMultilineText: true,
      nearbyText: nil
    )
    let response: LocalAIRefinementResponse?
    let rawCandidate: String
    if style.kind == .verbatim {
      response = nil
      rawCandidate = text
    } else {
      try await refiner.prepare(settings: selectedSettings)
      let generated = try await refiner.refine(
        LocalAIRefinementRequest(
          sessionID: sessionID,
          transcript: text,
          context: context,
          dictionary: selectedSettings.dictionary,
          additionalInstructions:
            selectedSettings.additionalInstructions,
          style: style,
          casingPolicy: selectedSettings.effectiveCasingPolicy
        ),
        settings: selectedSettings
      )
      response = generated
      rawCandidate = generated.text
    }
    let candidate = casingTransformer.apply(
      selectedSettings.effectiveCasingPolicy,
      to: rawCandidate,
      preserving: text,
      dictionary: selectedSettings.dictionary
    )
    let validated = try validator.validate(
      candidate,
      preserving: text,
      dictionary: selectedSettings.dictionary,
      supportsMultiline: true,
      context: context
    )
    let document = try builder.build(
      formattedText: validated,
      rawText: text,
      style: style,
      provider: response?.provider,
      modelIdentifier: response?.modelIdentifier,
      promptRevision:
        response == nil
        ? nil : VersionedLocalAIPromptBuilder.currentRevision
    )
    return VoiceHistoryReformat(
      text: try renderer.render(
        document,
        supportsMultiline: true
      ),
      document: document
    )
  }

  private func acquireOperation() async {
    guard operationInProgress else {
      operationInProgress = true
      return
    }
    await withCheckedContinuation { continuation in
      operationWaiters.append(continuation)
    }
  }

  private func releaseOperation() {
    guard !operationWaiters.isEmpty else {
      operationInProgress = false
      return
    }
    operationWaiters.removeFirst().resume()
  }
}
