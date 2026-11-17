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
      ),
      caretMarker: AccessibilityTextMarker("caret" as CFString)
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
    #expect(guarded.caretMarker == target.caretMarker)
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

  @Test
  func captureSettlingWakesOnceThenWaitsForAnEditableField() throws {
    var clock = SettlingClock()
    var reads = 0
    var wakes = 0
    let target = try FocusedTextCaptureSettling.standard.capture(
      now: { clock.now },
      sleep: { clock.advance($0) },
      wake: { wakes += 1 },
      attempt: { () -> FocusedTextCaptureAttempt<Int> in
        reads += 1
        return reads < 4 ? .settling : .captured(reads)
      }
    )

    #expect(target == 4)
    #expect(wakes == 1)
    #expect(clock.slept == .milliseconds(20))
  }

  @Test
  func captureSettlingNeverWakesAReadyField() throws {
    var clock = SettlingClock()
    var wakes = 0
    let target = try FocusedTextCaptureSettling.standard.capture(
      now: { clock.now },
      sleep: { clock.advance($0) },
      wake: { wakes += 1 },
      attempt: { () -> FocusedTextCaptureAttempt<Int> in .captured(1) }
    )

    #expect(target == 1)
    #expect(wakes == 0)
    #expect(clock.slept == .zero)
  }

  @Test
  func captureSettlingFailsOnceTheBoundPasses() {
    var clock = SettlingClock()
    #expect(throws: TranscriptionFailure.noFocusedTextField) {
      try FocusedTextCaptureSettling.standard.capture(
        now: { clock.now },
        sleep: { clock.advance($0) },
        wake: {},
        attempt: { () -> FocusedTextCaptureAttempt<Int> in .settling }
      )
    }
    #expect(clock.slept == FocusedTextCaptureSettling.standard.timeout)
  }

  @Test
  func captureSettlingNeverRetriesADefinitiveFailure() {
    var clock = SettlingClock()
    var reads = 0
    #expect(throws: TranscriptionFailure.secureTextField) {
      try FocusedTextCaptureSettling.standard.capture(
        now: { clock.now },
        sleep: { clock.advance($0) },
        wake: {},
        attempt: { () throws -> FocusedTextCaptureAttempt<Int> in
          reads += 1
          throw TranscriptionFailure.secureTextField
        }
      )
    }
    #expect(reads == 1)
    #expect(clock.slept == .zero)
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

/// A manual clock: only the settle loop's own sleeps move time forward.
private struct SettlingClock {
  let start = ContinuousClock.now
  var slept: Duration = .zero

  var now: ContinuousClock.Instant {
    start + slept
  }

  mutating func advance(_ duration: Duration) {
    slept += duration
  }
}
