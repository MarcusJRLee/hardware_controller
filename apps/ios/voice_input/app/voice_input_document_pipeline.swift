import Foundation
import HardwareControllerVoiceCore

struct VoiceInputProcessedTranscript: Codable, Equatable, Sendable {
  let rawTranscript: VoiceInputRawTranscript
  let editedText: String
  let spokenEdits: VoiceSpokenEditResult
  let formattedDocument: VoiceFormattedDocument
  let formattedText: String
}

struct VoiceInputDocumentPipeline: Sendable {
  private let spokenEditEngine = VoiceSpokenEditEngine()
  private let casingTransformer = VoiceCasingTransformer()
  private let documentBuilder = VoiceFormattedDocumentBuilder()
  private let renderer = VoiceFormattedTextRenderer()

  func process(
    _ rawTranscript: VoiceInputRawTranscript,
    style: VoiceStyle,
    casingPolicy: VoiceCasingPolicy = .styleDefault,
    dictionary: PersonalDictionary = .empty
  ) throws -> VoiceInputProcessedTranscript {
    let spokenEdits =
      style.kind == .verbatim
      ? VoiceSpokenEditResult(
        sourceText: rawTranscript.text,
        editedText: rawTranscript.text,
        operations: []
      )
      : spokenEditEngine.apply(to: rawTranscript.text)
    let casedText = casingTransformer.apply(
      casingPolicy,
      to: spokenEdits.editedText,
      preserving: spokenEdits.editedText,
      dictionary: dictionary
    )
    let document = try documentBuilder.build(
      formattedText: casedText,
      rawText: rawTranscript.text,
      style: style
    )
    return VoiceInputProcessedTranscript(
      rawTranscript: rawTranscript,
      editedText: spokenEdits.editedText,
      spokenEdits: spokenEdits,
      formattedDocument: document,
      formattedText: try renderer.render(document, supportsMultiline: true)
    )
  }
}
