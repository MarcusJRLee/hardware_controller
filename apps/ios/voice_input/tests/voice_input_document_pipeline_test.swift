import HardwareControllerVoiceCore
import XCTest

@testable import VoiceInput

final class VoiceInputDocumentPipelineTest: XCTestCase {
  func testSpokenEditsProduceValidatedSemanticBlocksWithoutChangingRawEvidence() throws {
    let raw = VoiceInputRawTranscript(
      text:
        "Keep this sentence. Remove this scratch that Intro new paragraph start a numbered list First item new paragraph Second item end list Outro",
      segments: [
        VoiceInputTranscriptSegment(
          startMilliseconds: 0,
          endMilliseconds: 2_000,
          text: "Keep this sentence. Remove this scratch that"
        ),
        VoiceInputTranscriptSegment(
          startMilliseconds: 2_000,
          endMilliseconds: 5_000,
          text:
            "Intro new paragraph start a numbered list First item new paragraph Second item end list Outro"
        ),
      ],
      modelPackageID: "com.longdevity.whisper.tiny_en",
      modelVersion: "b4938"
    )

    let result = try VoiceInputDocumentPipeline().process(
      raw,
      style: .natural
    )

    XCTAssertEqual(result.rawTranscript, raw)
    XCTAssertEqual(
      result.editedText,
      "Keep this sentence. Intro\n\n1. First item\n2. Second item\n\nOutro"
    )
    XCTAssertEqual(
      result.spokenEdits.operations.map(\.kind),
      [
        .deleteCurrentClause,
        .insertParagraphBreak,
        .beginOrderedList,
        .beginOrderedListItem,
        .endList,
      ]
    )
    XCTAssertEqual(result.formattedDocument.rawText, raw.text)
    XCTAssertEqual(
      result.formattedDocument.blocks.map(\.kind),
      [.paragraph, .orderedList, .paragraph]
    )
    XCTAssertEqual(
      result.formattedText,
      "Keep this sentence. Intro\n\n1. First item\n2. Second item\n\nOutro"
    )
    XCTAssertEqual(result.formattedDocument.validationStatus, .validated)
  }

  func testVerbatimPreservesLiteralTextAndSkipsSpokenCommands() throws {
    let raw = VoiceInputRawTranscript(
      text: "Keep this scratch that",
      segments: [],
      modelPackageID: "model",
      modelVersion: "1"
    )

    let result = try VoiceInputDocumentPipeline().process(
      raw,
      style: .verbatim
    )

    XCTAssertEqual(result.editedText, raw.text)
    XCTAssertEqual(result.formattedText, raw.text)
    XCTAssertEqual(result.spokenEdits.operations, [])
    XCTAssertEqual(result.formattedDocument.blocks.map(\.kind), [.verbatim])
  }

  func testStrictLowercaseAppliesAfterSpokenEdits() throws {
    let raw = VoiceInputRawTranscript(
      text: "Buy Milk new paragraph Call parseJSON",
      segments: [],
      modelPackageID: "model",
      modelVersion: "1"
    )

    let result = try VoiceInputDocumentPipeline().process(
      raw,
      style: .natural,
      casingPolicy: .strictLowercase
    )

    XCTAssertEqual(result.editedText, "Buy Milk\n\nCall parseJSON")
    XCTAssertEqual(result.formattedText, "buy milk\n\ncall parseJSON")
  }

  func testDelimitedGroceryCueUsesSharedTypedListNormalization() throws {
    let raw = VoiceInputRawTranscript(
      text: "Grocery list: Milk, Eggs, and Bread",
      segments: [],
      modelPackageID: "model",
      modelVersion: "1"
    )

    let result = try VoiceInputDocumentPipeline().process(
      raw,
      style: .natural,
      casingPolicy: .strictLowercase
    )

    XCTAssertEqual(
      result.formattedDocument.blocks.map(\.kind),
      [.paragraph, .unorderedList]
    )
    XCTAssertEqual(
      result.formattedText,
      "grocery list:\n\n- milk\n- eggs\n- bread"
    )
    XCTAssertNil(result.formattedDocument.evidence.first?.provider)
    XCTAssertNil(result.formattedDocument.evidence.first?.modelIdentifier)
    XCTAssertNil(result.formattedDocument.evidence.first?.promptRevision)
  }
}
