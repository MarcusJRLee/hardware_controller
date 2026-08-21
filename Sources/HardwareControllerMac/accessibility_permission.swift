import AppKit
@preconcurrency import ApplicationServices
import Foundation

public enum AccessibilityPermission {
  public static var isTrusted: Bool {
    AXIsProcessTrusted()
  }

  /// Prompts asynchronously through macOS and returns the current trust state.
  @discardableResult
  public static func request() -> Bool {
    let options =
      [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
      ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  public static func openSystemSettings() {
    guard
      let url = URL(
        string:
          "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}
