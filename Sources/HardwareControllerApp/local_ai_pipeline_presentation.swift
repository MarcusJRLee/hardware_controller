import Foundation
import HardwareControllerCore
import HardwareControllerMac

struct LocalAIPipelinePresentation: Equatable, Sendable {
  let speechProvider: String
  let speechModel: String
  let formattingProvider: String
  let formattingModel: String
  let formattingOutput: String
  let effectiveCasing: String
  let fallback: String
  let validation: String

  init(
    settings: LocalAISettings,
    speechEngine: SpeechEngineConfiguration,
    operatingSystemVersion: OperatingSystemVersion =
      ProcessInfo.processInfo.operatingSystemVersion
  ) {
    switch speechEngine.selection {
    case .transcribeCpp:
      speechProvider = "transcribe.cpp (local service)"
      speechModel =
        speechEngine.package.map { "\($0.displayName) · \($0.version)" }
        ?? "Not installed — Dictation is off until it is downloaded"
    case .apple:
      speechProvider = "Apple On-Device"
      speechModel =
        operatingSystemVersion.majorVersion >= 26
        ? "SpeechAnalyzer + DictationTranscriber (OS-managed)"
        : "SFSpeechRecognizer (OS-managed)"
    }
    formattingOutput =
      "Typed paragraph/list blocks · prompt r\(VersionedLocalAIPromptBuilder.currentRevision)"
    effectiveCasing = Self.casingTitle(settings.effectiveCasingPolicy)
    fallback = "Edited transcript"
    validation = "Protected text + semantic bounds"

    if settings.style.kind == .verbatim {
      formattingProvider = "None — Verbatim"
      formattingModel = "Not used"
    } else {
      switch settings.provider {
      case .appleOnDevice:
        formattingProvider = "Apple On-Device"
        formattingModel = "SystemLanguageModel (OS-managed)"
      case .ollama:
        formattingProvider = "Ollama (localhost)"
        formattingModel = Self.ollamaModelTitle(settings.ollamaModel)
      }
    }
  }

  private static func ollamaModelTitle(
    _ selection: LocalAIModelSelection
  ) -> String {
    guard let digest = selection.expectedDigest else {
      return selection.name
    }
    return "\(selection.name) @ \(digest.prefix(12))…"
  }

  private static func casingTitle(_ policy: VoiceCasingPolicy) -> String {
    switch policy {
    case .styleDefault:
      "Style Default"
    case .lowercaseProse:
      "Lowercase Prose"
    case .strictLowercase:
      "Strict Lowercase"
    }
  }
}
