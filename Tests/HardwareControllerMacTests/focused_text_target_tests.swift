import ApplicationServices
import CoreGraphics
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct FocusedTextTargetTests {
  @Test
  func ownershipPolicyClassifiesEveryLeaseInvalidation() {
    #expect(
      FocusedTextTargetOwnershipPolicy.failure(
        expectedProcessIdentifier: 42,
        currentProcessIdentifier: nil,
        currentIsSecure: false,
        isSameElement: false
      ) == .focusChanged
    )
    #expect(
      FocusedTextTargetOwnershipPolicy.failure(
        expectedProcessIdentifier: 42,
        currentProcessIdentifier: 84,
        currentIsSecure: false,
        isSameElement: false
      ) == .processChanged
    )
    #expect(
      FocusedTextTargetOwnershipPolicy.failure(
        expectedProcessIdentifier: 42,
        currentProcessIdentifier: 42,
        currentIsSecure: true,
        isSameElement: true
      ) == .secureStatusChanged
    )
    #expect(
      FocusedTextTargetOwnershipPolicy.failure(
        expectedProcessIdentifier: 42,
        currentProcessIdentifier: 42,
        currentIsSecure: false,
        isSameElement: false
      ) == .focusChanged
    )
    #expect(
      FocusedTextTargetOwnershipPolicy.failure(
        expectedProcessIdentifier: 42,
        currentProcessIdentifier: 42,
        currentIsSecure: false,
        isSameElement: true
      ) == nil
    )
  }

  @Test
  func guardedDeliveryPreservesTheCapturedRoute() throws {
    let anchor = FocusedTextRange(location: 9, length: 0)
    let target = FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      applicationName: "Browser",
      selectedRange: anchor,
      deliveryCapability: .bufferedEvent(
        anchor: anchor,
        destination: .focusedForeground
      )
    )

    let guarded = try target.guardedDeliveryCopy()

    #expect(
      guarded.deliveryCapability
        == .bufferedEvent(
          anchor: anchor,
          destination: .focusedForeground
        )
    )
    #expect(guarded.guardsCapturedCaret)
  }

  @Test
  func guardedDeliveryRequiresAnEmptyCapturedCaret() {
    let missing = FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      applicationName: "Notes"
    )
    let selection = FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      applicationName: "Notes",
      selectedRange: FocusedTextRange(location: 3, length: 2)
    )

    #expect(throws: TranscriptionFailure.noFocusedTextField) {
      try missing.guardedDeliveryCopy()
    }
    #expect(throws: TranscriptionFailure.noFocusedTextField) {
      try selection.guardedDeliveryCopy()
    }
  }
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
