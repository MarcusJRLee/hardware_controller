import Foundation
import Testing

@testable import HardwareControllerCore

struct AskGeminiPanelLayoutTest {
  private let laptop = display("laptop", x: 0, y: 0)
  private let dell = display("dell", x: -2228, y: 1117)
  private let lg = display("lg", x: 780, y: 1117)

  @Test
  func lockPointSurvivesDisplayRearrangement() {
    let frame = PanelRect(x: 149, y: 1735, width: 630, height: 1044)
    let lockPoint = AskGeminiLockPoint(frame: frame, on: dell)
    let moved = display("dell", x: 4000, y: 0)

    #expect(lockPoint.frame(on: dell) == frame)
    #expect(lockPoint.frame(on: moved) == PanelRect(x: 6377, y: 618, width: 630, height: 1044))
  }

  @Test
  func opensAtLockPointWhenItsDisplayIsConnected() {
    let lockFrame = PanelRect(x: 149, y: 1735, width: 630, height: 1044)
    let settings = AskGeminiPanelSettings(lockPoint: AskGeminiLockPoint(frame: lockFrame, on: dell))

    let placement = open(settings, active: "dell")

    #expect(placement?.displayID == "dell")
    #expect(placement?.frame == lockFrame)
  }

  @Test
  func opensAwayFromTheActiveDisplayPreferringTheLastOne() {
    let missingLock = AskGeminiPanelSettings(
      lockPoint: AskGeminiLockPoint(
        frame: PanelRect(x: 0, y: 0, width: 10, height: 10), on: display("gone", x: 0, y: 0))
    )
    let remembered = PanelRect(x: 900, y: 1200, width: 400, height: 600)

    #expect(open(.default, active: "lg")?.displayID == "laptop")
    #expect(
      open(missingLock, active: "laptop", last: "lg", remembered: ["lg": remembered])?.frame
        == remembered)
    #expect(open(.default, active: "lg", last: "lg")?.displayID == "laptop")
  }

  @Test
  func singleDisplayOpensOnItAndNoDisplayOpensNothing() {
    #expect(
      AskGeminiPanelPlacement.openingFrame(
        settings: .default, displays: [laptop], activeDisplayID: "laptop",
        lastDisplayID: nil, rememberedFrames: [:]
      )?.frame == AskGeminiPanelPlacement.defaultFrame(on: laptop)
    )
    #expect(
      AskGeminiPanelPlacement.openingFrame(
        settings: .default, displays: [], activeDisplayID: nil,
        lastDisplayID: nil, rememberedFrames: [:]
      ) == nil
    )
  }

  @Test
  func lockStateToleratesRoundingAndReportsEveryCase() {
    let frame = PanelRect(x: 149, y: 1735, width: 630, height: 1044)
    let settings = AskGeminiPanelSettings(lockPoint: AskGeminiLockPoint(frame: frame, on: dell))
    let nudged = PanelRect(x: 149.6, y: 1735.4, width: 630, height: 1044)
    let moved = PanelRect(x: 300, y: 1735, width: 630, height: 1044)

    #expect(lockState(nudged, .default) == .unset)
    #expect(lockState(nudged, settings) == .atLockPoint)
    #expect(lockState(moved, settings) == .away)
    #expect(
      AskGeminiPanelPlacement.lockState(of: frame, settings: settings, displays: [laptop]) == .away)
  }

  @Test
  func containingDisplayIsTheLargestOverlapOrNone() {
    let straddling = PanelRect(x: 700, y: 1500, width: 400, height: 100)

    #expect(AskGeminiPanelPlacement.display(containing: straddling, in: displays)?.id == "lg")
    #expect(
      AskGeminiPanelPlacement.display(
        containing: PanelRect(x: 90_000, y: 0, width: 10, height: 10), in: displays
      ) == nil
    )
  }

  @Test
  func zoomStepsStopAtEitherEndAndSnapStoredValues() {
    #expect(AskGeminiPanelSettings(zoom: 1.0).steppedZoom(increasing: false) == 0.9)
    #expect(AskGeminiPanelSettings(zoom: 1.0).steppedZoom(increasing: true) == 1.1)
    #expect(AskGeminiPanelSettings(zoom: 0.5).steppedZoom(increasing: false) == nil)
    #expect(AskGeminiPanelSettings(zoom: 2.0).steppedZoom(increasing: true) == nil)
    #expect(AskGeminiPanelSettings(zoom: 0.93).zoom == 0.9)
    #expect(AskGeminiPanelSettings(zoom: 40).zoom == 2.0)
    #expect(AskGeminiPanelSettings(zoom: .nan).zoom == 1.0)
  }

  @Test
  func decodingDropsUnusableLockPointsAndDefaultsMissingFields() throws {
    let decoded = try decode(
      #"{"lockPoint":{"displayID":"dell","x":0,"y":0,"width":-5,"height":10},"zoom":0.8}"#)
    let empty = try decode("{}")
    let valid = AskGeminiPanelSettings(
      lockPoint: AskGeminiLockPoint(frame: PanelRect(x: 1, y: 2, width: 3, height: 4), on: dell),
      zoom: 0.9
    )

    #expect(decoded == AskGeminiPanelSettings(lockPoint: nil, zoom: 0.8))
    #expect(empty == .default)
    #expect(try decode(String(decoding: JSONEncoder().encode(valid), as: UTF8.self)) == valid)
  }

  @Test
  func shortcutsMapToCommands() {
    let shortcuts: [(UInt16, Set<KeyModifier>, AskGeminiPanelCommand)] = [
      (48, [.control], .nextChat),
      (48, [.control, .shift], .previousChat),
      (30, [.command, .shift], .nextChat),
      (33, [.command, .shift], .previousChat),
      (17, [.command], .newChat),
      (13, [.command], .closeChat),
      (24, [.command, .shift], .zoomIn),
      (27, [.command, .shift], .zoomOut),
      (29, [.command, .shift], .zoomReset),
      (18, [.command], .selectChat(0)),
      (28, [.command], .selectChat(7)),
      (25, [.command], .lastChat),
    ]
    for (keyCode, modifiers, command) in shortcuts {
      #expect(AskGeminiPanelCommand.command(keyCode: keyCode, modifiers: modifiers) == command)
    }
  }

  @Test
  func unrelatedKeysAreLeftForTheWebPage() {
    // Plain ⌘- and ⌘= stay with Gemini; zoom needs Shift.
    #expect(AskGeminiPanelCommand.command(keyCode: 27, modifiers: [.command]) == nil)
    #expect(AskGeminiPanelCommand.command(keyCode: 24, modifiers: [.command]) == nil)
    #expect(AskGeminiPanelCommand.command(keyCode: 8, modifiers: [.command]) == nil)
    #expect(AskGeminiPanelCommand.command(keyCode: 48, modifiers: []) == nil)
  }

  private var displays: [AskGeminiDisplay] { [laptop, dell, lg] }

  private func open(
    _ settings: AskGeminiPanelSettings,
    active: String?,
    last: String? = nil,
    remembered: [String: PanelRect] = [:]
  ) -> (displayID: String, frame: PanelRect)? {
    AskGeminiPanelPlacement.openingFrame(
      settings: settings,
      displays: displays,
      activeDisplayID: active,
      lastDisplayID: last,
      rememberedFrames: remembered
    )
  }

  private func lockState(_ frame: PanelRect, _ settings: AskGeminiPanelSettings)
    -> AskGeminiLockState
  {
    AskGeminiPanelPlacement.lockState(of: frame, settings: settings, displays: displays)
  }

  private func decode(_ json: String) throws -> AskGeminiPanelSettings {
    try JSONDecoder().decode(AskGeminiPanelSettings.self, from: Data(json.utf8))
  }
}

private func display(_ id: String, x: Double, y: Double) -> AskGeminiDisplay {
  let frame = PanelRect(x: x, y: y, width: 2560, height: 1440)
  return AskGeminiDisplay(
    id: id,
    frame: frame,
    visibleFrame: PanelRect(x: x, y: y, width: 2560, height: 1400)
  )
}
