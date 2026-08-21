import CoreGraphics
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct TranscriptionIndicatorTests {
  @Test
  func localAIPhasesRemainVisibleThroughRefinement() {
    let snapshot = LocalAIDictationSnapshot(
      sessionID: UUID(),
      phase: .refining,
      volatileText: "",
      rawText: "draft text",
      refinedText: "",
      targetApplicationName: "Notes",
      failure: nil
    )

    let presentation = TranscriptionIndicatorPolicy.presentation(
      for: snapshot
    )

    #expect(presentation?.kind == .finalizing)
    #expect(presentation?.title == "Refining")
    #expect(presentation?.transcript == "draft text")
  }

  @Test
  func passiveAndInlineStatesDoNotPresentAnIndicator() {
    #expect(
      TranscriptionIndicatorPolicy.presentation(
        for: TranscriptionSnapshot.idle
      ) == nil
    )
    #expect(
      TranscriptionIndicatorPolicy.presentation(
        for: TranscriptionSnapshot(
          sessionID: UUID(),
          phase: .listening,
          volatileText: "visible in field",
          finalText: "",
          targetApplicationName: "Notes",
          failure: nil,
          showsInlineProvisionalText: true
        )
      ) == nil
    )
  }

  @Test
  func compatibilityTargetPresentsOnlyANonemptyActiveTranscript() {
    let presentation =
      TranscriptionIndicatorPolicy.presentation(
        for: TranscriptionSnapshot(
          sessionID: UUID(),
          phase: .listening,
          volatileText: "hello terminal",
          finalText: "",
          targetApplicationName: "Terminal",
          failure: nil,
          showsInlineProvisionalText: false
        )
      )

    #expect(presentation?.kind == .listening)
    #expect(presentation?.transcript == "hello terminal")
  }

  @Test
  func compatibilityTranscriptHasAStableSize() {
    #expect(
      TranscriptionIndicatorPlacement.size(
        showsDetails: true
      ) == CGSize(width: 316, height: 48)
    )
  }

  @Test
  func caretAnchorPlacesIndicatorBesideInsertionPoint() {
    let origin = TranscriptionIndicatorPlacement.origin(
      caretAnchor: CGPoint(x: 300, y: 200),
      size: CGSize(width: 316, height: 48),
      visibleFrame: CGRect(
        x: 0,
        y: 0,
        width: 1_000,
        height: 800
      )
    )

    #expect(origin == CGPoint(x: 312, y: 176))
  }

  @Test
  func missingCaretUsesStableScreenEdgePlacement() {
    let origin = TranscriptionIndicatorPlacement.origin(
      caretAnchor: nil,
      size: CGSize(width: 316, height: 48),
      visibleFrame: CGRect(
        x: 0,
        y: 0,
        width: 1_000,
        height: 800
      )
    )

    #expect(origin == CGPoint(x: 342, y: 28))
  }

  @Test
  func placementStaysInsideVisibleScreen() {
    let origin = TranscriptionIndicatorPlacement.origin(
      caretAnchor: CGPoint(x: 995, y: 5),
      size: CGSize(width: 316, height: 48),
      visibleFrame: CGRect(
        x: 0,
        y: 0,
        width: 1_000,
        height: 800
      )
    )

    #expect(origin == CGPoint(x: 676, y: 8))
  }
}
