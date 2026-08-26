import SwiftUI

/// Hosts the three durable destinations in one native macOS window.
struct ApplicationShellView: View {
  @Bindable var navigation: ApplicationNavigationModel
  let model: AppModel
  let preferencesModel: ApplicationPreferencesModel
  let historyModel: VoiceHistoryModel

  @State private var columnVisibility: NavigationSplitViewVisibility

  /// Creates the shell with the user's persisted sidebar visibility.
  init(
    model: AppModel,
    navigation: ApplicationNavigationModel,
    preferencesModel: ApplicationPreferencesModel,
    historyModel: VoiceHistoryModel
  ) {
    self.model = model
    self.navigation = navigation
    self.preferencesModel = preferencesModel
    self.historyModel = historyModel
    _columnVisibility = State(
      initialValue:
        preferencesModel.sidebarVisibility == .collapsed
        ? .detailOnly : .all
    )
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebar
        .navigationSplitViewColumnWidth(
          min: 180,
          ideal: 210,
          max: 250
        )
    } detail: {
      destination
        .navigationTitle(navigation.selectedDestination.title)
    }
    .navigationSplitViewStyle(.balanced)
    .onChange(of: columnVisibility) { _, visibility in
      let preference: SidebarVisibilityPreference =
        visibility == .detailOnly ? .collapsed : .expanded
      guard
        preferencesModel.setSidebarVisibility(preference)
      else {
        columnVisibility =
          preferencesModel.sidebarVisibility == .collapsed
          ? .detailOnly : .all
        return
      }
    }
    .frame(minWidth: 1_000, minHeight: 660)
    .tint(StudioDesign.accent)
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      List(
        AppDestination.allCases,
        selection: $navigation.selectedDestination
      ) { destination in
        Label(destination.title, systemImage: destination.systemImage)
          .tag(destination)
      }
      .listStyle(.sidebar)
      .accessibilityLabel("Application destinations")

      Divider()

      VStack(alignment: .leading, spacing: 7) {
        Text("ACTIVE PROFILE")
          .font(.caption2.weight(.semibold))
          .tracking(0.7)
          .foregroundStyle(.secondary)

        Picker(
          "Active Profile",
          selection: Binding(
            get: { model.envelope.activeProfileID },
            set: { model.activateProfile(id: $0) }
          )
        ) {
          ForEach(model.profiles) { profile in
            Text(profile.name).tag(profile.id)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityLabel("Active Profile")
      }
      .padding(14)
    }
  }

  @ViewBuilder
  private var destination: some View {
    switch navigation.selectedDestination {
    case .controller:
      ControllerView(
        model: model,
        manageProfiles: { navigation.select(.profiles) }
      )
    case .history:
      VoiceHistoryView(model: historyModel)
    case .profiles:
      ProfilesView(model: model)
    case .general:
      GeneralSettingsView(
        model: model,
        preferencesModel: preferencesModel
      )
    }
  }
}
