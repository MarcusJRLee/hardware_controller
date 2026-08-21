import Testing

@testable import HardwareControllerMac

struct ControllerMenuBarIconTests {
  @Test
  @MainActor
  func idleAndActiveIconsAreDistinctTemplateImages() throws {
    let idle = ControllerMenuBarIcon.image(active: false)
    let active = ControllerMenuBarIcon.image(active: true)

    #expect(idle.size.width == 18)
    #expect(idle.size.height == 18)
    #expect(idle.isTemplate)
    #expect(active.isTemplate)
    #expect(
      try #require(idle.tiffRepresentation)
        != #require(active.tiffRepresentation)
    )
  }
}
