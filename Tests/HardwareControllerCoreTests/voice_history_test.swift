import Foundation
import Testing

@testable import HardwareControllerCore

struct VoiceHistoryTest {
  @Test
  func correctedTextIsPreferredWithoutReplacingEarlierEvidence() {
    let sessionID = UUID()
    let raw = result(
      sessionID: sessionID,
      stage: .raw,
      text: "first draft"
    )
    let formatted = result(
      sessionID: sessionID,
      stage: .formatted,
      text: "First draft.",
      sourceResultID: raw.id
    )
    let correction = result(
      sessionID: sessionID,
      stage: .corrected,
      text: "Final draft.",
      sourceResultID: formatted.id
    )
    let results = [raw, formatted, correction]

    #expect(results.preferredReusableResult == correction)
    #expect(results[0] == raw)
    #expect(results[1] == formatted)
  }

  @Test
  func emptyCorrectionDoesNotHideReusableFormattedText() {
    let sessionID = UUID()
    let formatted = result(
      sessionID: sessionID,
      stage: .formatted,
      text: "Keep this."
    )
    let emptyCorrection = result(
      sessionID: sessionID,
      stage: .corrected,
      text: "",
      sourceResultID: formatted.id
    )

    #expect(
      [formatted, emptyCorrection].preferredReusableResult
        == formatted
    )
  }

  private func result(
    sessionID: UUID,
    stage: VoiceHistoryTextStage,
    text: String,
    sourceResultID: UUID? = nil
  ) -> VoiceHistoryResult {
    VoiceHistoryResult(
      sessionID: sessionID,
      createdAt: Date(timeIntervalSince1970: 1_000),
      stage: stage,
      origin: stage == .corrected ? .correction : .capture,
      text: text,
      sourceResultID: sourceResultID
    )
  }
}
