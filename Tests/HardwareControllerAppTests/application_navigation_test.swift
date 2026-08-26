import Testing

@testable import HardwareControllerApp

@MainActor
struct ApplicationNavigationModelTests {
  /// Opens Controller by default and supports explicit destination routing.
  @Test
  func routesDurableDestinations() {
    let model = ApplicationNavigationModel()
    #expect(model.selectedDestination == .controller)

    model.select(.profiles)
    #expect(model.selectedDestination == .profiles)
    model.select(.history)
    #expect(model.selectedDestination == .history)
    model.select(.general)
    #expect(model.selectedDestination == .general)
  }

  /// Selects deterministic Profiles and General demo destinations.
  @Test
  func resolvesDemoDestinations() {
    #expect(
      ApplicationNavigationModel(arguments: ["--ui-profiles"])
        .selectedDestination == .profiles
    )
    #expect(
      ApplicationNavigationModel(arguments: ["--ui-history"])
        .selectedDestination == .history
    )
    #expect(
      ApplicationNavigationModel(arguments: ["--ui-general"])
        .selectedDestination == .general
    )
  }

  /// Gives General precedence when deterministic flags conflict.
  @Test
  func conflictingDemoDestinationsUseGeneral() {
    #expect(
      ApplicationNavigationModel(
        arguments: ["--ui-profiles", "--ui-general"]
      ).selectedDestination == .general
    )
  }
}
