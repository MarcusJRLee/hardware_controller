@preconcurrency import ApplicationServices
import Foundation
import Testing

@testable import HardwareControllerMac

struct LocalAIContextTests {
  @Test
  func utf16BoundNeverSplitsACharacter() {
    #expect(
      AccessibilityLocalAIContextCapturer.boundedUTF16Prefix(
        "ab😀cd",
        maximumUnits: 3
      ) == "ab"
    )
    #expect(
      AccessibilityLocalAIContextCapturer.boundedUTF16Prefix(
        "ab😀cd",
        maximumUnits: 4
      ) == "ab😀"
    )
  }

  @Test
  func includesNearbyTextOnlyForAnApprovedMultilineTarget() {
    let target = makeTarget(supportsMultilineText: true)
    let capturer = AccessibilityLocalAIContextCapturer {
      _, maximumUTF16Units in
      #expect(maximumUTF16Units == 600)
      return "Nearby project context"
    }

    let context = capturer.capture(
      for: target,
      profileName: "Coding",
      locale: Locale(identifier: "en_US"),
      includeNearbyText: true
    )

    #expect(context.applicationName == "Notes")
    #expect(context.profileName == "Coding")
    #expect(context.supportsMultilineText)
    #expect(context.nearbyText == "Nearby project context")
  }

  @Test
  func omitsNearbyTextForSingleLineAndDisabledTargets() {
    let capturer = AccessibilityLocalAIContextCapturer {
      _, _ in
      Issue.record("Nearby text must not be read.")
      return "unexpected"
    }

    let singleLine = capturer.capture(
      for: makeTarget(supportsMultilineText: false),
      profileName: "Coding",
      locale: .current,
      includeNearbyText: true
    )
    let disabled = capturer.capture(
      for: makeTarget(supportsMultilineText: true),
      profileName: "Coding",
      locale: .current,
      includeNearbyText: false
    )

    #expect(singleLine.nearbyText == nil)
    #expect(disabled.nearbyText == nil)
  }

  private func makeTarget(
    supportsMultilineText: Bool
  ) -> FocusedTextTarget {
    FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 41,
      applicationName: "Notes",
      applicationBundleIdentifier: "com.apple.Notes",
      role: supportsMultilineText ? "AXTextArea" : "AXTextField",
      supportsMultilineText: supportsMultilineText,
      selectedRange: FocusedTextRange(location: 12, length: 0)
    )
  }
}
