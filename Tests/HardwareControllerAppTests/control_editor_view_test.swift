import AppKit
import HardwareControllerCore
import Testing

@testable import HardwareControllerApp

@MainActor
struct ControlEditorViewTests {
  /// Requires every Action menu icon to exist in the supported system catalog.
  @Test
  func actionIconsResolveToSystemImages() {
    for kind in ActionKind.allCases {
      #expect(
        NSImage(
          systemSymbolName: kind.systemImage,
          accessibilityDescription: nil
        ) != nil,
        "\(kind.displayTitle) uses an unavailable system image."
      )
    }
  }
}
