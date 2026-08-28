import Foundation
import HardwareControllerCore

/// Applies the selected local formatter to one immutable History source result.
public actor LocalAIVoiceHistoryReformatter:
  VoiceHistoryReformatting
{
  private let refiner: any LocalAIRefinementRouting
  private let validator = RefinedTranscriptValidator()
  private let draftPolisher = VoiceFormattingDraftPolisher()
  private let draftNormalizer = VoiceFormattingDraftNormalizer()
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
    let document: VoiceFormattedDocument
    if style.kind == .verbatim {
      let candidate = casingTransformer.apply(
        selectedSettings.effectiveCasingPolicy,
        to: text,
        preserving: text,
        dictionary: selectedSettings.dictionary
      )
      document = try builder.build(
        formattedText: candidate,
        rawText: text,
        style: style
      )
    } else {
      try await refiner.prepare(settings: selectedSettings)
      let request = LocalAIRefinementRequest(
        sessionID: sessionID,
        transcript: text,
        context: context,
        dictionary: selectedSettings.dictionary,
        additionalInstructions:
          selectedSettings.additionalInstructions,
        style: style,
        casingPolicy: selectedSettings.effectiveCasingPolicy
      )
      let generated = try await refiner.refine(
        request,
        settings: selectedSettings
      )
      let normalized = draftNormalizer.normalize(
        generated.output,
        transcript: text,
        intent: request.listIntent
      )
      let polished = draftPolisher.polish(
        normalized,
        preserving: text,
        style: style
      )
      let output = casingTransformer.apply(
        selectedSettings.effectiveCasingPolicy,
        to: polished,
        preserving: text,
        dictionary: selectedSettings.dictionary
      )
      document = try builder.build(
        output: output,
        rawText: text,
        style: style,
        provider: generated.provider,
        modelIdentifier: generated.modelIdentifier,
        promptRevision: VersionedLocalAIPromptBuilder.currentRevision
      )
    }
    let formattedText = try renderer.render(
      document,
      supportsMultiline: true
    )
    _ = try validator.validate(
      formattedText,
      preserving: text,
      dictionary: selectedSettings.dictionary,
      supportsMultiline: true,
      context: context
    )
    return VoiceHistoryReformat(
      text: formattedText,
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
