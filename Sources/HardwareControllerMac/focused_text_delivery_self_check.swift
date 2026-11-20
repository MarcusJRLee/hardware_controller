// Tested by: Tests/HardwareControllerMacTests/focused_text_target_tests.swift.
import AppKit
@preconcurrency import ApplicationServices
import Foundation
import HardwareControllerCore

/// Proves Dictation delivery into the focused text field of one app.
///
/// `Hardware Controller --verify-focused-text-delivery PID MARKER` waits until
/// PID owns the frontmost window, captures its focused field with the
/// production targeter, delivers MARKER once through the production writer
/// after a press-length hold, and reads the field back. It must be launched
/// by LaunchServices (`open -n -g`) so the app's own Accessibility grant
/// applies. Launching can still take keyboard focus from the target, so the
/// caller activates PID after launch and this check waits for it using
/// window-server state alone, never Accessibility, which would wake the
/// target's accessibility tree before the capture under test.
public enum FocusedTextDeliverySelfCheck {
  public struct Report: Sendable {
    public var lines: [String] = []
    public var passed = true

    mutating func record(_ line: String, passed: Bool = true) {
      lines.append("\(passed ? "PASS" : "FAIL") \(line)")
      self.passed = self.passed && passed
    }
  }

  public static func run(
    targetProcessIdentifier: pid_t,
    marker: String,
    activationTimeout: Duration = .seconds(10),
    hold: Duration = .seconds(1),
    readBackTimeout: Duration = .seconds(2)
  ) async -> Report {
    var report = Report()
    guard AccessibilityPermission.isTrusted else {
      report.record("accessibility not trusted; launch with open -n", passed: false)
      return report
    }
    let activationDeadline = ContinuousClock.now + activationTimeout
    while frontmostWindowOwner() != targetProcessIdentifier {
      guard ContinuousClock.now < activationDeadline else {
        report.record(
          "activation: pid \(targetProcessIdentifier) never owned the frontmost window",
          passed: false)
        return report
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    let targeter = AccessibilityFocusedTextTargeting()
    let start = ContinuousClock.now
    let target: FocusedTextTarget
    do {
      target = try targeter.capture().guardedDeliveryCopy()
    } catch {
      report.record(
        "capture: \(error) ms=\(milliseconds(since: start)) \(describeFocus())",
        passed: false
      )
      return report
    }
    report.record(
      "capture ms=\(milliseconds(since: start)) route=\(route(of: target.deliveryCapability)) "
        + "role=\(target.role ?? "none")"
    )

    // A real press delivers only after speech ends, so ownership must survive
    // the gap, including any accessibility tree the first capture woke up.
    try? await Task.sleep(for: hold)
    do {
      try SafeTranscriptWriter(
        targeter: targeter,
        inserter: AdaptiveFocusedTextInserter()
      ).insert(marker, into: target)
    } catch {
      let current = AdaptiveFocusedTextInserter().selectedRange(in: target)
      report.record(
        "insert: \(error) captured=\(describe(target.selectedRange)) current=\(describe(current))",
        passed: false
      )
      return report
    }

    // Buffered events reach the field asynchronously, so poll the value.
    let deadline = ContinuousClock.now + readBackTimeout
    while ContinuousClock.now < deadline {
      if value(of: target.element)?.contains(marker) == true {
        report.record("delivered ms=\(milliseconds(since: start))")
        return report
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    let ownership = targeter.ownershipFailure(for: target).map { "\($0)" } ?? "intact"
    report.record(
      "delivered: marker absent from the field; ownership=\(ownership)",
      passed: false
    )
    return report
  }

  /// Reads the owner of the topmost normal window from the window server.
  private static func frontmostWindowOwner() -> pid_t? {
    let windows =
      CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]] ?? []
    return windows.first { ($0[kCGWindowLayer as String] as? Int) == 0 }?[
      kCGWindowOwnerPID as String
    ] as? pid_t
  }

  /// Names what capture saw, without reading any field text.
  private static func describeFocus() -> String {
    guard let front = NSWorkspace.shared.frontmostApplication else {
      return "frontmost=none"
    }
    let frontmost = "frontmost=\(front.bundleIdentifier ?? "unknown")[\(front.processIdentifier)]"
    let application = AXUIElementCreateApplication(front.processIdentifier)
    var window: CFTypeRef?
    let windowResult = AXUIElementCopyAttributeValue(
      application, kAXFocusedWindowAttribute as CFString, &window)
    var focusedApplication: CFTypeRef?
    AXUIElementCopyAttributeValue(
      AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focusedApplication
    )
    var keyboardPID: pid_t = 0
    if let focusedApplication, CFGetTypeID(focusedApplication) == AXUIElementGetTypeID() {
      AXUIElementGetPid(unsafeDowncast(focusedApplication, to: AXUIElement.self), &keyboardPID)
    }
    let prefix = frontmost + " focusedWindow=\(windowResult.rawValue) keyboardApp=\(keyboardPID)"
    var value: CFTypeRef?
    let focusedResult = AXUIElementCopyAttributeValue(
      application,
      kAXFocusedUIElementAttribute as CFString,
      &value
    )
    guard
      focusedResult == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return "\(prefix) focused=none(\(focusedResult.rawValue))"
    }
    let element = unsafeDowncast(value, to: AXUIElement.self)
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    var settable = DarwinBoolean(false)
    let settableResult = AXUIElementIsAttributeSettable(
      element,
      kAXSelectedTextAttribute as CFString,
      &settable
    )
    return "\(prefix) focused=\((role as? String) ?? "unknown") "
      + "selectedTextSettable=\(settableResult == .success && settable.boolValue)"
  }

  private static func describe(_ range: FocusedTextRange?) -> String {
    range.map { "\($0.location)+\($0.length)" } ?? "none"
  }

  private static func route(
    of capability: FocusedTextDeliveryCapability
  ) -> String {
    switch capability {
    case .finalOnly:
      "accessibility"
    case .liveComposition:
      "live"
    case .bufferedEvent(_, .capturedProcess):
      "terminal"
    case .bufferedEvent(_, .focusedForeground):
      "web"
    }
  }

  private static func value(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXValueAttribute as CFString,
        &value
      ) == .success
    else {
      return nil
    }
    return value as? String
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = ContinuousClock.now - start
    return Int(elapsed.components.seconds * 1000)
      + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
  }
}
