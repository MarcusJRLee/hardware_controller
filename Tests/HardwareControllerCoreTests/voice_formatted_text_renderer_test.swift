import Foundation
import Testing

@testable import HardwareControllerCore

struct VoiceFormattedTextRendererTest {
  @Test
  func legacyRawFallbackStatusDecodesAsSourceFallback() throws {
    let status = try JSONDecoder().decode(
      VoiceFormattingValidationStatus.self,
      from: Data("\"rawFallback\"".utf8)
    )

    #expect(status == .sourceFallback)
  }

  @Test
  func preservesStructureOnlyForMultilineTargets() throws {
    let document = try VoiceFormattedDocumentBuilder().build(
      formattedText:
        "Plan.\n\n- Keep Bash.\n- Keep https://example.com.",
      rawText:
        "plan keep Bash keep https://example.com",
      style: .technical
    )
    let renderer = VoiceFormattedTextRenderer()

    #expect(
      try renderer.render(document, supportsMultiline: true)
        == "Plan.\n\n- Keep Bash.\n- Keep https://example.com."
    )
    let singleLine = try renderer.render(
      document,
      supportsMultiline: false
    )

    #expect(
      singleLine
        == "Plan. Keep Bash.; Keep https://example.com."
    )
    #expect(!singleLine.contains("\n"))
    #expect(singleLine.contains("Bash"))
    #expect(singleLine.contains("https://example.com"))
  }

  @Test
  func verbatimPreservesOnlySupportedTargetStructure() throws {
    let text = "first keep this\nsecond keep that"
    let document = try VoiceFormattedDocumentBuilder().build(
      formattedText: text,
      rawText: text,
      style: .verbatim
    )
    let renderer = VoiceFormattedTextRenderer()

    #expect(try renderer.render(document, supportsMultiline: true) == text)
    #expect(
      try renderer.render(document, supportsMultiline: false)
        == "first keep this second keep that"
    )
  }

  @Test
  func decodedBlockCannotInjectAControlCharacter() {
    let document = VoiceFormattedDocument(
      rawText: "safe unsafe",
      style: .natural,
      blocks: [
        VoiceFormattedBlock(
          kind: .paragraph,
          items: ["Safe\nunsafe"],
          evidenceIndices: [0]
        )
      ],
      evidence: [
        VoiceFormattingEvidence(
          rawUTF8StartOffset: 0,
          rawUTF8EndOffset: 11,
          provider: nil,
          modelIdentifier: nil,
          promptRevision: nil
        )
      ],
      validationStatus: .validated
    )

    #expect(throws: VoiceFormattingError.unsafeControlCharacter) {
      try VoiceFormattedTextRenderer().render(
        document,
        supportsMultiline: false
      )
    }
  }
}
