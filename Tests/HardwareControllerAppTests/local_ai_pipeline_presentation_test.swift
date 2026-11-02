import Foundation
import Testing

@testable import HardwareControllerApp
@testable import HardwareControllerCore
@testable import HardwareControllerMac

struct LocalAIPipelinePresentationTest {
  private static let apple = SpeechEngineConfiguration(selection: .apple, package: nil)

  /// transcribe.cpp names its package, or says Dictation is off without one.
  @Test
  func namesTheTranscribeCppPackageOrItsAbsence() {
    let package = InstalledASRModelPackage(
      rootURL: URL(filePath: "/tmp/p"),
      packageID: "com.longdevity.asr.parakeet_tdt_v3",
      version: "d8d8c32-q8_0",
      displayName: "Parakeet TDT 0.6B v3",
      manifestSHA256: Data(repeating: 0, count: 32)
    )
    let installed = LocalAIPipelinePresentation(
      settings: .default,
      speechEngine: SpeechEngineConfiguration(selection: .transcribeCpp, package: package)
    )
    #expect(installed.speechProvider == "transcribe.cpp (local service)")
    #expect(installed.speechModel == "Parakeet TDT 0.6B v3 · d8d8c32-q8_0")
    let missing = LocalAIPipelinePresentation(settings: .default, speechEngine: .unconfigured)
    #expect(missing.speechModel.contains("Dictation is off"))
  }

  @Test
  func distinguishesAppleSpeechFromOllamaFormatting() {
    var settings = LocalAISettings.default
    settings.provider = .ollama
    settings.additionalInstructions = "only provide text in lowercase"

    let presentation = LocalAIPipelinePresentation(
      settings: settings,
      speechEngine: Self.apple,
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
      speechEngine: Self.apple,
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
