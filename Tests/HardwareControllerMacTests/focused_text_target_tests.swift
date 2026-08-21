import ApplicationServices
import CoreGraphics
import Testing

@testable import HardwareControllerMac

struct FocusedTextTargetTests {
  /// Routes standard web-content ancestry without application identity.
  @Test
  func webContentUsesForegroundBufferedDelivery() {
    let metadata = FocusedTextTargetMetadata(
      applicationBundleIdentifier: nil,
      role: kAXTextFieldRole as String,
      roleDescription: "text field",
      description: "Search",
      identifier: nil,
      contextLabels: [],
      contextRoles: ["AXWebArea"]
    )

    #expect(
      FocusedTextDeliveryPolicy.bufferedEventDestination(
        for: metadata
      ) == .focusedForeground
    )
  }

  /// Exercises semantic web-target capture against a real focused field.
  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_RUN_WEB_TARGET_INTEGRATION"
        ] == "1"
    )
  )
  func focusedWebContentUsesForegroundBufferedDelivery()
    throws
  {
    let target =
      try AccessibilityFocusedTextTargeting().capture()
    guard
      case .bufferedEvent(_, .focusedForeground) =
        target.deliveryCapability
    else {
      Issue.record(
        "The focused target was not editable web content."
      )
      return
    }
  }

  @Test
  func nativeTerminalSearchFieldIsNotATerminalTarget() {
    let metadata = FocusedTextTargetMetadata(
      applicationBundleIdentifier: "com.apple.Terminal",
      role: kAXTextFieldRole as String,
      roleDescription: "text field",
      description: "Find",
      identifier: "search",
      contextLabels: ["Find"],
      contextRoles: []
    )

    #expect(
      !FocusedTextDeliveryPolicy.isTerminal(metadata)
    )
    #expect(
      FocusedTextDeliveryPolicy.bufferedEventDestination(
        for: metadata
      ) == nil
    )
  }

  @Test
  func convertsAccessibilityBoundsToAppKitCoordinates() {
    let point = AccessibilityCaretGeometry.appKitPoint(
      bounds: CGRect(
        x: 120,
        y: 310,
        width: 2,
        height: 18
      ),
      mainScreenMaxY: 900
    )

    #expect(point == CGPoint(x: 122, y: 572))
  }
}
