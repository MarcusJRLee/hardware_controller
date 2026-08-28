import Foundation
import Testing

@testable import HardwareControllerApp
@testable import HardwareControllerCore

struct LocalAIPipelinePresentationTest {
  @Test
  func distinguishesAppleSpeechFromOllamaFormatting() {
    var settings = LocalAISettings.default
    settings.provider = .ollama
    settings.additionalInstructions = "only provide text in lowercase"

    let presentation = LocalAIPipelinePresentation(
      settings: settings,
      operatingSystemVersion: OperatingSystemVersion(
        majorVersion: 26,
        minorVersion: 0,
        patchVersion: 0
      )
    )

    #expect(presentation.speechProvider == "Apple On-Device")
    #expect(
      presentation.speechModel
        == "SpeechAnalyzer + DictationTranscriber (OS-managed)"
    )
    #expect(presentation.formattingProvider == "Ollama (localhost)")
    #expect(presentation.formattingModel.contains("qwen3.5:4b"))
    #expect(presentation.effectiveCasing == "Strict Lowercase")
    #expect(presentation.fallback == "Edited transcript")
    #expect(presentation.validation == "Protected text + semantic bounds")
  }

  @Test
  func verbatimMakesFormattingBypassExplicit() {
    var settings = LocalAISettings.default
    settings.style = .verbatim

    let presentation = LocalAIPipelinePresentation(
      settings: settings,
      operatingSystemVersion: OperatingSystemVersion(
        majorVersion: 25,
        minorVersion: 0,
        patchVersion: 0
      )
    )

    #expect(presentation.speechModel == "SFSpeechRecognizer (OS-managed)")
    #expect(presentation.formattingProvider == "None — Verbatim")
    #expect(presentation.formattingModel == "Not used")
  }
}
