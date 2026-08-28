import Testing

@testable import HardwareControllerCore

struct VoiceFormattedDocumentBuilderTest {
  @Test
  func everyInitialStyleKeepsTheSameRawEvidence() throws {
    let raw = "first run Git status second open https://example.com"
    let builder = VoiceFormattedDocumentBuilder()

    let documents = try VoiceStyleKind.allCases.map { kind in
      try builder.build(
        formattedText:
          "1. Run Git status.\n2. Open https://example.com.",
        rawText: raw,
        style: VoiceStyle(kind: kind)
      )
    }

    #expect(documents.map(\.rawText) == Array(repeating: raw, count: 5))
    #expect(documents.map(\.style.kind) == VoiceStyleKind.allCases)
    #expect(
      documents.allSatisfy {
        $0.evidence == [
          VoiceFormattingEvidence(
            rawUTF8StartOffset: 0,
            rawUTF8EndOffset: raw.utf8.count,
            provider: nil,
            modelIdentifier: nil,
            promptRevision: nil
          )
        ]
      })
  }

  @Test
  func ordinalTextBecomesOneEvidenceBackedOrderedList() throws {
    let document = try VoiceFormattedDocumentBuilder().build(
      formattedText:
        "1. Install Git.\n2. Run bash --version.",
      rawText:
        "first install Git second run bash --version",
      style: .technical,
      provider: .ollama,
      modelIdentifier: "qwen3.5:4b",
      promptRevision: 5
    )

    #expect(
      document.blocks == [
        VoiceFormattedBlock(
          kind: .orderedList,
          items: ["Install Git.", "Run bash --version."],
          evidenceIndices: [0]
        )
      ])
    #expect(document.validationStatus == .validated)
    #expect(document.evidence.first?.provider == .ollama)
  }

  @Test
  func spokenOrdinalsBecomeBlocksWhenTheModelReturnsProse() throws {
    let document = try VoiceFormattedDocumentBuilder().build(
      formattedText:
        "There are three steps: first, stop the service; second, copy the backup; third, restart the service.",
      rawText:
        "there are three steps first stop the service second copy the backup third restart the service",
      style: .natural
    )

    #expect(
      document.blocks == [
        VoiceFormattedBlock(
          kind: .paragraph,
          items: ["There are three steps:"],
          evidenceIndices: [0]
        ),
        VoiceFormattedBlock(
          kind: .orderedList,
          items: [
            "stop the service",
            "copy the backup",
            "restart the service.",
          ],
          evidenceIndices: [0]
        ),
      ])
  }

  @Test
  func verbatimNeverInterpretsOrdinalsOrMultilineStructure() throws {
    let text = "first keep this\nsecond keep that"
    let document = try VoiceFormattedDocumentBuilder().build(
      formattedText: text,
      rawText: text,
      style: .verbatim
    )

    #expect(
      document.blocks == [
        VoiceFormattedBlock(
          kind: .verbatim,
          items: [text],
          evidenceIndices: [0]
        )
      ])
  }

  @Test
  func incompleteOrdinalEvidenceRemainsProse() throws {
    let text = "First do one thing. Second do the other and then finish."
    let document = try VoiceFormattedDocumentBuilder().build(
      formattedText: text,
      rawText: "first do one thing second do another third finish",
      style: .natural
    )

    #expect(
      document.blocks == [
        VoiceFormattedBlock(
          kind: .paragraph,
          items: [text],
          evidenceIndices: [0]
        )
      ])
  }

  @Test
  func unsupportedStyleRevisionIsRejected() {
    #expect(throws: VoiceFormattingError.unsupportedStyleRevision(99)) {
      try VoiceFormattedDocumentBuilder().build(
        formattedText: "Text.",
        rawText: "text",
        style: VoiceStyle(kind: .natural, revision: 99)
      )
    }
  }
}
