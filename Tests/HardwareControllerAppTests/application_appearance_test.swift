import AppKit
import Testing

@testable import HardwareControllerApp

struct ApplicationAppearanceTests {
  /// Resolves each unambiguous deterministic demo appearance.
  @Test
  func resolvesDemoAppearanceOverrides() {
    #expect(
      ApplicationAppearance.demoOverride(arguments: ["--ui-light"])
        == .light
    )
    #expect(
      ApplicationAppearance.demoOverride(arguments: ["--ui-dark"])
        == .dark
    )
    #expect(ApplicationAppearance.demoOverride(arguments: []) == nil)
  }

  /// Resolves conflicting deterministic flags conservatively to System.
  @Test
  func conflictingDemoAppearanceUsesSystem() {
    #expect(
      ApplicationAppearance.demoOverride(
        arguments: ["--ui-light", "--ui-dark"]
      ) == .system
    )
  }
}

@MainActor
struct AppKitApplicationAppearanceAdapterTests {
  /// Maps every typed preference onto the native application seam.
  @Test
  func appliesNativeApplicationAppearance() {
    let application = NSApplication.shared
    let original = application.appearance
    defer { application.appearance = original }
    let adapter = AppKitApplicationAppearanceAdapter(
      application: application
    )

    adapter.apply(.dark)
    #expect(application.appearance?.name == .darkAqua)
    adapter.apply(.light)
    #expect(application.appearance?.name == .aqua)
    adapter.apply(.system)
    #expect(application.appearance == nil)
  }
}
