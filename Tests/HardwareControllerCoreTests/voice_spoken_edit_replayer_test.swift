import Foundation
import Testing

@testable import HardwareControllerCore

struct VoiceSpokenEditReplayerTest {
  private let replayer = VoiceSpokenEditReplayer()

  @Test
  func typedOperationsRoundTripThroughJSON() throws {
    let result = VoiceSpokenEditEngine().apply(
      to: "Keep this. Remove this scratch that Add this."
    )

    let encoded = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(
      VoiceSpokenEditResult.self,
      from: encoded
    )

    #expect(decoded == result)
    #expect(try replayer.replay(decoded) == decoded.editedText)
  }

  @Test
  func rejectsOverlappingSourceEvidence() {
    let operations = [
      VoiceSpokenEditOperation(
        kind: .preserveLiteralCommand,
        sourceUTF8StartOffset: 0,
        sourceUTF8EndOffset: 20,
        editedUTF8StartOffset: 0,
        editedUTF8EndOffset: 0,
        replacementText: "scratch that"
      ),
      VoiceSpokenEditOperation(
        kind: .preserveLiteralCommand,
        sourceUTF8StartOffset: 19,
        sourceUTF8EndOffset: 20,
        editedUTF8StartOffset: 12,
        editedUTF8EndOffset: 12,
        replacementText: "x"
      ),
    ]

    #expect(throws: VoiceSpokenEditError.operationsOutOfOrder) {
      try replayer.replay(
        sourceText: "literal scratch that",
        operations: operations
      )
    }
  }

  @Test
  func rejectsAnEditOutsideTheConstructedSuffix() {
    let operation = VoiceSpokenEditOperation(
      kind: .deleteCurrentClause,
      sourceUTF8StartOffset: 4,
      sourceUTF8EndOffset: 16,
      editedUTF8StartOffset: 0,
      editedUTF8EndOffset: 3,
      replacementText: ""
    )

    #expect(throws: VoiceSpokenEditError.invalidEditedRange) {
      try replayer.replay(
        sourceText: "one scratch that",
        operations: [operation]
      )
    }
  }

  @Test
  func rejectsAReplacementThatDoesNotMatchItsOperationKind() {
    let operation = VoiceSpokenEditOperation(
      kind: .insertParagraphBreak,
      sourceUTF8StartOffset: 4,
      sourceUTF8EndOffset: 17,
      editedUTF8StartOffset: 3,
      editedUTF8EndOffset: 4,
      replacementText: " unsafe "
    )

    #expect(throws: VoiceSpokenEditError.invalidReplacement) {
      try replayer.replay(
        sourceText: "one new paragraph",
        operations: [operation]
      )
    }
  }

  @Test
  func rejectsAStoredResultWhoseEditedTextWasChanged() {
    let valid = VoiceSpokenEditEngine().apply(
      to: "Wrong scratch that Right"
    )
    let mismatched = VoiceSpokenEditResult(
      sourceText: valid.sourceText,
      editedText: "Changed",
      operations: valid.operations
    )

    #expect(throws: VoiceSpokenEditError.resultMismatch) {
      try replayer.validate(mismatched)
    }
  }

  @Test
  func rejectsCommandEvidenceThatDoesNotMatchItsKind() {
    let operation = VoiceSpokenEditOperation(
      kind: .deleteCurrentClause,
      sourceUTF8StartOffset: 4,
      sourceUTF8EndOffset: 9,
      editedUTF8StartOffset: 0,
      editedUTF8EndOffset: 4,
      replacementText: ""
    )

    #expect(throws: VoiceSpokenEditError.invalidCommandEvidence) {
      try replayer.replay(
        sourceText: "one erase",
        operations: [operation]
      )
    }
  }

  @Test
  func rejectsAReplayableEditThatCrossesTheCanonicalStableBoundary()
    throws
  {
    let canonical = VoiceSpokenEditEngine().apply(
      to: "Keep this. Remove this scratch that"
    )
    let operation = try #require(canonical.operations.first)
    let destructive = VoiceSpokenEditOperation(
      kind: operation.kind,
      sourceUTF8StartOffset: operation.sourceUTF8StartOffset,
      sourceUTF8EndOffset: operation.sourceUTF8EndOffset,
      editedUTF8StartOffset: 0,
      editedUTF8EndOffset: operation.editedUTF8EndOffset,
      replacementText: ""
    )
    let result = VoiceSpokenEditResult(
      sourceText: canonical.sourceText,
      editedText: "",
      operations: [destructive]
    )

    #expect(throws: VoiceSpokenEditError.nonCanonicalOperations) {
      try replayer.validate(result)
    }
  }

  @Test
  func rejectsAnUnsupportedTraceRevision() {
    let result = VoiceSpokenEditResult(
      revision: VoiceSpokenEditResult.currentRevision + 1,
      sourceText: "text",
      editedText: "text",
      operations: []
    )

    #expect(
      throws: VoiceSpokenEditError.unsupportedRevision(
        VoiceSpokenEditResult.currentRevision + 1
      )
    ) {
      try replayer.validate(result)
    }
  }
}
