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
  private let documentBuilder = VoiceFormattedDocumentBuilder()
  private let renderer = VoiceFormattedTextRenderer()

  func process(
    _ rawTranscript: VoiceInputRawTranscript,
    style: VoiceStyle
  ) throws -> VoiceInputProcessedTranscript {
    let spokenEdits =
      style.kind == .verbatim
      ? VoiceSpokenEditResult(
        sourceText: rawTranscript.text,
        editedText: rawTranscript.text,
        operations: []
      )
      : spokenEditEngine.apply(to: rawTranscript.text)
    let document = try documentBuilder.build(
      formattedText: spokenEdits.editedText,
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
