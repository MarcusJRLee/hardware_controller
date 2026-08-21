import AppKit

extension ApplicationAppearance {
  /// Resolves deterministic demo appearance flags without ambiguity.
  static func demoOverride(arguments: [String]) -> ApplicationAppearance? {
    let requestsLight = arguments.contains("--ui-light")
    let requestsDark = arguments.contains("--ui-dark")
    switch (requestsLight, requestsDark) {
    case (true, true):
      return .system
    case (true, false):
      return .light
    case (false, true):
      return .dark
    case (false, false):
      return nil
    }
  }
}

/// Applies appearance through the native application-wide AppKit seam.
@MainActor
final class AppKitApplicationAppearanceAdapter:
  ApplicationAppearanceApplying
{
  private weak var application: NSApplication?

  /// Creates one adapter around the running application.
  init(application: NSApplication = NSApp) {
    self.application = application
  }

  /// Maps the typed preference onto the native appearance override.
  func apply(_ appearance: ApplicationAppearance) {
    switch appearance {
    case .system:
      application?.appearance = nil
    case .light:
      application?.appearance = NSAppearance(named: .aqua)
    case .dark:
      application?.appearance = NSAppearance(named: .darkAqua)
    }
  }
}
