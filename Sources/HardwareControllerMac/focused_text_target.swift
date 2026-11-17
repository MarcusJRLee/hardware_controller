import AppKit
@preconcurrency import ApplicationServices
import Foundation
import HardwareControllerCore

public struct FocusedTextRange: Equatable, Sendable {
  public let location: Int
  public let length: Int

  public init(location: Int, length: Int) {
    self.location = location
    self.length = length
  }
}

/// An opaque caret position from `AXSelectedTextMarkerRange`.
///
/// Web engines number a caret by text offsets that also count text around
/// the field, such as a placeholder, so an empty Gemini prompt reports 10
/// and then 38 while its caret never moves. Text markers name the caret's
/// node and offset instead; they stay equal across those page changes and
/// change when the caret moves. Equality is `CFEqual`.
public struct AccessibilityTextMarker: Equatable, @unchecked Sendable {
  let value: CFTypeRef

  init(_ value: CFTypeRef) {
    self.value = value
  }

  public static func == (
    lhs: AccessibilityTextMarker,
    rhs: AccessibilityTextMarker
  ) -> Bool {
    CFEqual(lhs.value, rhs.value)
  }
}

public enum BufferedTextEventDestination:
  Equatable,
  Sendable
{
  /// Routes text directly to the captured application process.
  case capturedProcess

  /// Routes text through the current foreground input path.
  case focusedForeground
}

public enum FocusedTextDeliveryCapability:
  Equatable,
  Sendable
{
  case finalOnly
  case liveComposition(anchor: FocusedTextRange)
  case bufferedEvent(
    anchor: FocusedTextRange,
    destination: BufferedTextEventDestination
  )

  var showsInlineProvisionalText: Bool {
    if case .liveComposition = self {
      return true
    }
    return false
  }
}

public enum FocusedTextTargetOwnershipFailure:
  Equatable,
  Sendable
{
  case focusChanged
  case processChanged
  case secureStatusChanged

  var transcriptionFailure: TranscriptionFailure {
    switch self {
    case .focusChanged:
      .focusChanged
    case .processChanged:
      .processChanged
    case .secureStatusChanged:
      .secureTextField
    }
  }
}

enum FocusedTextTargetOwnershipPolicy {
  static func failure(
    expectedProcessIdentifier: pid_t,
    currentProcessIdentifier: pid_t?,
    currentIsSecure: Bool,
    isSameElement: Bool
  ) -> FocusedTextTargetOwnershipFailure? {
    guard let currentProcessIdentifier else {
      return .focusChanged
    }
    guard currentProcessIdentifier == expectedProcessIdentifier else {
      return .processChanged
    }
    guard !currentIsSecure else {
      return .secureStatusChanged
    }
    guard isSameElement else {
      return .focusChanged
    }
    return nil
  }
}

struct FocusedTextTargetMetadata: Equatable, Sendable {
  let applicationBundleIdentifier: String?
  let role: String?
  let roleDescription: String?
  let description: String?
  let identifier: String?
  let contextLabels: [String]
  let contextRoles: [String]
}

private struct FocusedTextTargetContext {
  let labels: [String]
  let roles: [String]
}

enum FocusedTextDeliveryPolicy {
  private static let cursorBundleIdentifier =
    "com.todesktop.230313mzl4w4u92"
  // This raw role keeps web-content detection available before macOS 26.
  private static let webAreaRole = "AXWebArea"

  /// Resolves buffered event routing from semantic target evidence.
  static func bufferedEventDestination(
    for metadata: FocusedTextTargetMetadata
  ) -> BufferedTextEventDestination? {
    if isTerminal(metadata) {
      return .capturedProcess
    }
    if metadata.contextRoles.contains(webAreaRole) {
      return .focusedForeground
    }
    return nil
  }

  /// Identifies the physically validated terminal compatibility targets.
  static func isTerminal(
    _ metadata: FocusedTextTargetMetadata
  ) -> Bool {
    guard
      [
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
      ].contains(metadata.role)
    else {
      return false
    }

    guard
      let bundleIdentifier =
        metadata.applicationBundleIdentifier,
      bundleIdentifier == "com.apple.Terminal"
        || bundleIdentifier == cursorBundleIdentifier
    else {
      return false
    }

    let terminalEvidence = [
      metadata.roleDescription,
      metadata.description,
      metadata.identifier,
      metadata.contextLabels.joined(separator: " "),
    ]
    .compactMap { $0?.lowercased() }
    .joined(separator: " ")
    return ["terminal", "shell", "xterm"].contains {
      terminalEvidence.contains($0)
    }
  }
}

public final class FocusedTextTarget:
  @unchecked Sendable
{
  public let processIdentifier: pid_t
  public let applicationName: String
  public let applicationBundleIdentifier: String?
  public let role: String?
  public let supportsMultilineText: Bool
  public let selectedRange: FocusedTextRange?
  public let deliveryCapability: FocusedTextDeliveryCapability
  /// The caret as a text marker, when the target exposes one; delivery
  /// revalidates it in place of the numeric anchor.
  let caretMarker: AccessibilityTextMarker?
  let guardsCapturedCaret: Bool
  let element: AXUIElement

  init(
    element: AXUIElement,
    processIdentifier: pid_t,
    applicationName: String,
    applicationBundleIdentifier: String? = nil,
    role: String? = nil,
    supportsMultilineText: Bool = false,
    selectedRange: FocusedTextRange? = nil,
    deliveryCapability:
      FocusedTextDeliveryCapability = .finalOnly,
    caretMarker: AccessibilityTextMarker? = nil,
    guardsCapturedCaret: Bool = false
  ) {
    self.element = element
    self.processIdentifier = processIdentifier
    self.applicationName = applicationName
    self.applicationBundleIdentifier = applicationBundleIdentifier
    self.role = role
    self.supportsMultilineText = supportsMultilineText
    self.selectedRange = selectedRange
    self.deliveryCapability = deliveryCapability
    self.caretMarker = caretMarker
    self.guardsCapturedCaret = guardsCapturedCaret
  }

  /// A final-only target for text bound for this app's own UI rather than the
  /// focused app. Its element is never read or written.
  static func detachedFinalOnly(applicationName: String) -> FocusedTextTarget {
    let processIdentifier = ProcessInfo.processInfo.processIdentifier
    return FocusedTextTarget(
      element: AXUIElementCreateApplication(processIdentifier),
      processIdentifier: processIdentifier,
      applicationName: applicationName
    )
  }

  /// Keeps recognition final-only without changing the delivery target lease.
  func finalOnlyCopy() -> FocusedTextTarget {
    FocusedTextTarget(
      element: element,
      processIdentifier: processIdentifier,
      applicationName: applicationName,
      applicationBundleIdentifier: applicationBundleIdentifier,
      role: role,
      supportsMultilineText: supportsMultilineText,
      selectedRange: selectedRange,
      deliveryCapability: .finalOnly
    )
  }

  /// Preserves the route while requiring the original empty caret.
  func guardedDeliveryCopy() throws -> FocusedTextTarget {
    guard let selectedRange, selectedRange.length == 0 else {
      throw TranscriptionFailure.noFocusedTextField
    }
    return FocusedTextTarget(
      element: element,
      processIdentifier: processIdentifier,
      applicationName: applicationName,
      applicationBundleIdentifier: applicationBundleIdentifier,
      role: role,
      supportsMultilineText: supportsMultilineText,
      selectedRange: selectedRange,
      deliveryCapability: deliveryCapability,
      caretMarker: caretMarker,
      guardsCapturedCaret: true
    )
  }
}

public protocol FocusedTextTargeting: Sendable {
  func capture() throws -> FocusedTextTarget
  func isStillFocused(_ target: FocusedTextTarget) -> Bool
  func ownershipFailure(
    for target: FocusedTextTarget
  ) -> FocusedTextTargetOwnershipFailure?
}

extension FocusedTextTargeting {
  public func ownershipFailure(
    for target: FocusedTextTarget
  ) -> FocusedTextTargetOwnershipFailure? {
    isStillFocused(target) ? nil : .focusChanged
  }
}

/// One read of the focused element during capture.
enum FocusedTextCaptureAttempt<Target> {
  case captured(Target)
  /// No editable field is exposed yet; a later read may find one.
  case settling
}

/// Wakes on-demand page accessibility, then bounds the wait for an editor.
///
/// Chromium-family browsers build a page's accessibility tree only after an
/// application-level request and expose it asynchronously. Until then the
/// app reports no focus, a bare group, or the page's web area, so the first
/// press after the browser started, or after it dropped an idle tree, found
/// no field while the next press worked. The first settling read therefore
/// calls `wake` once, then capture re-reads until an editor appears or
/// `timeout` passes. Definitive failures, such as a secure field or an
/// existing selection, still throw at once.
struct FocusedTextCaptureSettling {
  static let standard = FocusedTextCaptureSettling(
    timeout: .milliseconds(500),
    pollInterval: .milliseconds(10)
  )

  let timeout: Duration
  let pollInterval: Duration

  func capture<Target>(
    now: () -> ContinuousClock.Instant = { ContinuousClock.now },
    sleep: (Duration) -> Void = { Thread.sleep(forTimeInterval: $0.seconds) },
    wake: () -> Void,
    attempt: () throws -> FocusedTextCaptureAttempt<Target>
  ) throws -> Target {
    let deadline = now() + timeout
    var hasWoken = false
    while true {
      if case .captured(let target) = try attempt() {
        return target
      }
      if !hasWoken {
        hasWoken = true
        wake()
        continue
      }
      guard now() < deadline else {
        throw TranscriptionFailure.noFocusedTextField
      }
      sleep(pollInterval)
    }
  }
}

extension Duration {
  fileprivate var seconds: TimeInterval {
    TimeInterval(components.seconds)
      + TimeInterval(components.attoseconds) / 1e18
  }
}

public struct AccessibilityFocusedTextTargeting:
  FocusedTextTargeting
{
  public init() {}

  /// Captures synchronously so commands queued behind a press still run in
  /// order; the bounded settle wait is no longer than a slow Accessibility
  /// call already is.
  public func capture() throws -> FocusedTextTarget {
    guard AccessibilityPermission.isTrusted else {
      throw TranscriptionFailure.noFocusedTextField
    }
    return try FocusedTextCaptureSettling.standard.capture(
      wake: wakeOnDemandAccessibility,
      attempt: captureOnce
    )
  }

  /// Asks the frontmost app for its role, the application-level request
  /// that makes Chromium-family browsers build page accessibility; asking
  /// for the focused element alone never does. Other apps answer it as a
  /// plain read.
  private func wakeOnDemandAccessibility() {
    guard let application = NSWorkspace.shared.frontmostApplication else {
      return
    }
    _ = attribute(
      kAXRoleAttribute,
      from: AXUIElementCreateApplication(application.processIdentifier)
    )
  }

  private func captureOnce() throws -> FocusedTextCaptureAttempt<FocusedTextTarget> {
    guard let element = focusedElement() else {
      return .settling
    }
    if attribute(
      kAXSubroleAttribute,
      from: element
    ) == kAXSecureTextFieldSubrole as String {
      throw TranscriptionFailure.secureTextField
    }

    var processIdentifier: pid_t = 0
    guard
      AXUIElementGetPid(
        element,
        &processIdentifier
      ) == .success
    else {
      throw TranscriptionFailure.noFocusedTextField
    }
    let application =
      NSRunningApplication(
        processIdentifier: processIdentifier
      )
    let applicationName =
      application?.localizedName
      ?? application?.bundleIdentifier
      ?? "Focused app"
    let context = context(from: element)
    let metadata = FocusedTextTargetMetadata(
      applicationBundleIdentifier:
        application?.bundleIdentifier,
      role: attribute(kAXRoleAttribute, from: element),
      roleDescription:
        attribute(kAXRoleDescriptionAttribute, from: element),
      description:
        attribute(kAXDescriptionAttribute, from: element),
      identifier:
        attribute(kAXIdentifierAttribute, from: element),
      contextLabels: context.labels,
      contextRoles: context.roles
    )
    let destination = FocusedTextDeliveryPolicy.bufferedEventDestination(
      for: metadata
    )
    // A terminal consumes events without exposing settable text. Everything
    // else, including web content, must expose an editable selection: a web
    // area or group without one is a page that has no editable focus yet.
    guard
      destination == .capturedProcess
        || isSettable(kAXSelectedTextAttribute, on: element)
    else {
      return .settling
    }
    let deliveryCapability: FocusedTextDeliveryCapability
    if let destination {
      guard let range = selectedTextRange(from: element) else {
        return .settling
      }
      guard range.length == 0 else {
        throw TranscriptionFailure.noFocusedTextField
      }
      deliveryCapability = .bufferedEvent(
        anchor: range,
        destination: destination
      )
    } else {
      deliveryCapability =
        liveCompositionAnchor(from: element).map {
          FocusedTextDeliveryCapability
            .liveComposition(anchor: $0)
        } ?? .finalOnly
    }

    return .captured(
      FocusedTextTarget(
        element: element,
        processIdentifier: processIdentifier,
        applicationName: applicationName,
        applicationBundleIdentifier: metadata.applicationBundleIdentifier,
        role: metadata.role,
        supportsMultilineText:
          metadata.role == kAXTextAreaRole as String
          && destination == nil,
        selectedRange: selectedTextRange(from: element),
        deliveryCapability: deliveryCapability,
        caretMarker: destination == .focusedForeground
          ? AccessibilityFocusedTextTargeting.caretMarker(of: element) : nil
      ))
  }

  static func caretMarker(of element: AXUIElement) -> AccessibilityTextMarker? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        "AXSelectedTextMarkerRange" as CFString,
        &value
      ) == .success,
      let value
    else {
      return nil
    }
    return AccessibilityTextMarker(value)
  }

  private func isSettable(
    _ attribute: String,
    on element: AXUIElement
  ) -> Bool {
    var isSettable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(
      element,
      attribute as CFString,
      &isSettable
    ) == .success && isSettable.boolValue
  }

  public func isStillFocused(
    _ target: FocusedTextTarget
  ) -> Bool {
    ownershipFailure(for: target) == nil
  }

  public func ownershipFailure(
    for target: FocusedTextTarget
  ) -> FocusedTextTargetOwnershipFailure? {
    guard let current = focusedElement() else {
      return .focusChanged
    }
    var processIdentifier: pid_t = 0
    let currentProcessIdentifier: pid_t? =
      AXUIElementGetPid(current, &processIdentifier) == .success
      ? processIdentifier : nil
    return FocusedTextTargetOwnershipPolicy.failure(
      expectedProcessIdentifier: target.processIdentifier,
      currentProcessIdentifier: currentProcessIdentifier,
      currentIsSecure:
        attribute(kAXSubroleAttribute, from: current)
        == kAXSecureTextFieldSubrole as String,
      isSameElement: CFEqual(current, target.element)
    )
  }

  public func focusedCaretPoint() -> CGPoint? {
    guard let element = focusedElement() else {
      return nil
    }
    guard
      attribute(
        kAXSubroleAttribute,
        from: element
      ) != kAXSecureTextFieldSubrole as String,
      let range = selectedTextRange(from: element)
    else {
      return nil
    }

    var rangeValue = CFRange(
      location: range.location,
      length: range.length
    )
    guard
      let parameter = AXValueCreate(.cfRange, &rangeValue)
    else {
      return nil
    }
    var value: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element,
        kAXBoundsForRangeParameterizedAttribute as CFString,
        parameter,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    let boundsValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(boundsValue) == .cgRect else {
      return nil
    }
    var bounds = CGRect.zero
    guard
      AXValueGetValue(boundsValue, .cgRect, &bounds),
      !bounds.isNull,
      !bounds.isInfinite
    else {
      return nil
    }

    return AccessibilityCaretGeometry.appKitPoint(
      bounds: bounds,
      mainScreenMaxY:
        NSScreen.screens.first?.frame.maxY ?? 0
    )
  }

  private func focusedElement() -> AXUIElement? {
    if let application =
      NSWorkspace.shared.frontmostApplication
    {
      let applicationElement = AXUIElementCreateApplication(
        application.processIdentifier
      )
      if let element = focusedElement(
        from: applicationElement
      ) {
        return element
      }
    }
    return focusedElement(
      from: AXUIElementCreateSystemWide()
    )
  }

  private func focusedElement(
    from owner: AXUIElement
  ) -> AXUIElement? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        owner,
        kAXFocusedUIElementAttribute as CFString,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private func attribute(
    _ name: String,
    from element: AXUIElement
  ) -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        name as CFString,
        &value
      ) == .success
    else {
      return nil
    }
    return value as? String
  }

  /// Collects bounded semantic ancestry without reading target text.
  private func context(
    from element: AXUIElement
  ) -> FocusedTextTargetContext {
    var labels: [String] = []
    var roles: [String] = []
    var current: AXUIElement? = element
    for _ in 0..<32 {
      guard let owner = current else {
        break
      }
      if let role = attribute(
        kAXRoleAttribute,
        from: owner
      ) {
        roles.append(role)
      }
      for name in [
        kAXDescriptionAttribute,
        kAXRoleDescriptionAttribute,
        kAXTitleAttribute,
        kAXIdentifierAttribute,
      ] {
        if let label = attribute(name, from: owner),
          !label.isEmpty
        {
          labels.append(label)
        }
      }

      var value: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(
          owner,
          kAXParentAttribute as CFString,
          &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
      else {
        break
      }
      current = unsafeDowncast(value, to: AXUIElement.self)
    }
    return FocusedTextTargetContext(
      labels: labels,
      roles: roles
    )
  }

  private func liveCompositionAnchor(
    from element: AXUIElement
  ) -> FocusedTextRange? {
    guard
      isSettable(kAXSelectedTextRangeAttribute, on: element),
      let range = selectedTextRange(from: element)
    else {
      return nil
    }
    guard range.length == 0 else {
      return nil
    }
    return range
  }

  private func selectedTextRange(
    from element: AXUIElement
  ) -> FocusedTextRange? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    let rangeValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(rangeValue) == .cfRange else {
      return nil
    }
    var range = CFRange()
    guard
      AXValueGetValue(rangeValue, .cfRange, &range),
      range.location != kCFNotFound,
      range.location >= 0,
      range.length >= 0
    else {
      return nil
    }
    return FocusedTextRange(
      location: range.location,
      length: range.length
    )
  }
}

struct AccessibilityCaretGeometry {
  static func appKitPoint(
    bounds: CGRect,
    mainScreenMaxY: CGFloat
  ) -> CGPoint {
    CGPoint(
      x: bounds.maxX,
      y: mainScreenMaxY - bounds.maxY
    )
  }
}
