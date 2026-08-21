@preconcurrency import ApplicationServices
import Foundation
import HardwareControllerCore

public protocol LocalAIContextCapturing: Sendable {
  func capture(
    for target: FocusedTextTarget,
    profileName: String,
    locale: Locale,
    includeNearbyText: Bool
  ) -> LocalAITargetContext
}

public struct AccessibilityLocalAIContextCapturer:
  LocalAIContextCapturing
{
  private let nearbyText: @Sendable (FocusedTextTarget, Int) -> String?

  public init() {
    nearbyText = Self.copyNearbyText
  }

  init(
    nearbyText:
      @escaping @Sendable (FocusedTextTarget, Int) -> String?
  ) {
    self.nearbyText = nearbyText
  }

  public func capture(
    for target: FocusedTextTarget,
    profileName: String,
    locale: Locale,
    includeNearbyText: Bool
  ) -> LocalAITargetContext {
    LocalAITargetContext(
      localeIdentifier: locale.identifier,
      profileName: profileName,
      applicationName: target.applicationName,
      applicationBundleIdentifier:
        target.applicationBundleIdentifier,
      targetRole: target.role,
      supportsMultilineText: target.supportsMultilineText,
      nearbyText:
        includeNearbyText && target.supportsMultilineText
        ? nearbyText(target, 600) : nil
    )
  }

  /// Reads only one bounded range around the captured caret.
  private static func copyNearbyText(
    from target: FocusedTextTarget,
    maximumUTF16Units: Int
  ) -> String? {
    guard
      maximumUTF16Units > 0,
      let selection = target.selectedRange,
      let characterCount = numberOfCharacters(in: target.element),
      characterCount > 0
    else {
      return nil
    }
    let center = min(selection.location, characterCount)
    let halfWindow = maximumUTF16Units / 2
    let start = max(0, center - halfWindow)
    let end = min(characterCount, center + halfWindow)
    guard end > start else {
      return nil
    }

    var range = CFRange(location: start, length: end - start)
    guard let parameter = AXValueCreate(.cfRange, &range) else {
      return nil
    }
    var value: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        target.element,
        kAXStringForRangeParameterizedAttribute as CFString,
        parameter,
        &value
      ) == .success,
      let text = value as? String,
      !text.isEmpty
    else {
      return nil
    }
    return boundedUTF16Prefix(
      text,
      maximumUnits: maximumUTF16Units
    )
  }

  static func boundedUTF16Prefix(
    _ text: String,
    maximumUnits: Int
  ) -> String {
    guard maximumUnits > 0 else {
      return ""
    }
    var units = 0
    var end = text.startIndex
    while end < text.endIndex {
      let next = text.index(after: end)
      let characterUnits = text[end..<next].utf16.count
      guard units + characterUnits <= maximumUnits else {
        break
      }
      units += characterUnits
      end = next
    }
    return String(text[..<end])
  }

  private static func numberOfCharacters(
    in element: AXUIElement
  ) -> Int? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXNumberOfCharactersAttribute as CFString,
        &value
      ) == .success,
      let number = value as? NSNumber
    else {
      return nil
    }
    return max(0, number.intValue)
  }
}
