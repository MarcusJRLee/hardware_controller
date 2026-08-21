import Observation

/// Identifies one durable application-window destination.
enum AppDestination: String, CaseIterable, Hashable, Identifiable {
  case controller
  case profiles
  case general

  var id: Self { self }

  /// Returns the destination's visible label.
  var title: String {
    switch self {
    case .controller:
      "Controller"
    case .profiles:
      "Profiles"
    case .general:
      "General"
    }
  }

  /// Returns the destination's native sidebar symbol.
  var systemImage: String {
    switch self {
    case .controller:
      "slider.horizontal.3"
    case .profiles:
      "person.crop.rectangle.stack"
    case .general:
      "gearshape"
    }
  }
}

/// Owns application-window routing without product or persistence state.
@MainActor
@Observable
final class ApplicationNavigationModel {
  var selectedDestination: AppDestination

  /// Creates deterministic initial routing for normal and demo launches.
  init(arguments: [String] = []) {
    if arguments.contains("--ui-general") {
      selectedDestination = .general
    } else if arguments.contains("--ui-profiles") {
      selectedDestination = .profiles
    } else {
      selectedDestination = .controller
    }
  }

  /// Selects one destination before its application window is raised.
  func select(_ destination: AppDestination) {
    selectedDestination = destination
  }
}
