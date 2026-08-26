import Foundation
import Testing

@testable import HardwareControllerCore

struct VoiceSpokenEditEngineTest {
  private let engine = VoiceSpokenEditEngine()
  private let replayer = VoiceSpokenEditReplayer()

  @Test
  func scratchThatRemovesOnlyTheCurrentClause() throws {
    let source =
      "Keep this sentence. We should ship Friday scratch that We should ship Monday."

    let result = engine.apply(to: source)

    #expect(result.sourceText == source)
    #expect(result.editedText == "Keep this sentence. We should ship Monday.")
    #expect(result.operations.map(\.kind) == [.deleteCurrentClause])
    #expect(try replayer.replay(result) == result.editedText)
  }

  @Test
  func deleteThatSentencePreservesEarlierStableText() throws {
    let source =
      "Keep this. Remove this sentence. delete that sentence Add this."

    let result = engine.apply(to: source)

    #expect(result.editedText == "Keep this. Add this.")
    #expect(result.operations.map(\.kind) == [.deleteCurrentSentence])
    #expect(try replayer.replay(result) == result.editedText)
  }

  @Test
  func paragraphAndListCommandsProduceExplicitStructure() throws {
    let source =
      "Intro new paragraph start a numbered list First item new paragraph Second item end list Outro"

    let result = engine.apply(to: source)

    #expect(
      result.editedText
        == "Intro\n\n1. First item\n2. Second item\n\nOutro"
    )
    #expect(
      result.operations.map(\.kind) == [
        .insertParagraphBreak,
        .beginOrderedList,
        .beginOrderedListItem,
        .endList,
      ]
    )
    #expect(try replayer.replay(result) == result.editedText)
  }

  @Test
  func literalPreservesOnlyAnExactFollowingCommand() throws {
    let source =
      "Say literal scratch that and literal new paragraph exactly."

    let result = engine.apply(to: source)

    #expect(result.editedText == "Say scratch that and new paragraph exactly.")
    #expect(
      result.operations.map(\.kind) == [
        .preserveLiteralCommand,
        .preserveLiteralCommand,
      ]
    )
    #expect(try replayer.replay(result) == result.editedText)
  }

  @Test
  func nearMissesAndInapplicableCommandsRemainLiteral() {
    let source =
      "Scratch those notes, delete the sentence, start numbered list, end the list, end list."

    let result = engine.apply(to: source)

    #expect(result.editedText == source)
    #expect(result.operations.isEmpty)
  }

  @Test
  func destructiveEditCannotRemoveTheActiveListMarker() throws {
    let source =
      "start a numbered list Wrong item scratch that Correct item end list Done."

    let result = engine.apply(to: source)

    #expect(result.editedText == "1. Correct item\n\nDone.")
    #expect(
      result.operations.map(\.kind) == [
        .beginOrderedList,
        .deleteCurrentClause,
        .endList,
      ]
    )
    #expect(try replayer.replay(result) == result.editedText)
  }

  @Test
  func unicodeEvidenceOffsetsReplayExactly() throws {
    let source = "Café 😊 scratch that résumé"

    let result = engine.apply(to: source)
    let operation = try #require(result.operations.first)

    #expect(result.editedText == "résumé")
    #expect(operation.sourceUTF8EndOffset <= source.utf8.count)
    #expect(try replayer.replay(result) == "résumé")
  }

  @Test
  func aCommandThatWouldDeleteNoTextRemainsLiteral() {
    let result = engine.apply(to: "scratch that")

    #expect(result.editedText == "scratch that")
    #expect(result.operations.isEmpty)
  }
}
