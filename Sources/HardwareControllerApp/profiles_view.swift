import Foundation
import HardwareControllerCore
import SwiftUI

/// Manages named work modes and their independent Device setups.
struct ProfilesView: View {
  let model: AppModel

  @State private var selectedProfileID: UUID?
  @State private var renameDraft = ""
  @State private var showsRename = false
  @State private var showsDeleteConfirmation = false

  /// Selects the active Profile when profile management first opens.
  init(model: AppModel) {
    self.model = model
    _selectedProfileID = State(
      initialValue: model.envelope.activeProfileID
    )
  }

  var body: some View {
    HStack(spacing: 0) {
      profileList

      Divider()

      if let selectedProfile {
        profileEditor(selectedProfile)
      } else {
        ContentUnavailableView(
          "Select a Profile",
          systemImage: "person.crop.rectangle.stack",
          description: Text(
            "Choose a work mode to configure its connected Devices."
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onChange(of: model.profiles.map(\.id)) {
      previousIDs,
      currentIDs in
      reconcileSelection(
        previousIDs: previousIDs,
        currentIDs: currentIDs
      )
    }
    .alert("Rename Profile", isPresented: $showsRename) {
      TextField("Profile name", text: $renameDraft)
      Button("Cancel", role: .cancel) {}
      Button("Rename") {
        guard let selectedProfileID else {
          return
        }
        model.renameProfile(id: selectedProfileID, name: renameDraft)
      }
      .disabled(
        renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty
      )
    }
    .alert(
      "Delete \(selectedProfile?.name ?? "Profile")?",
      isPresented: $showsDeleteConfirmation
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        deleteSelectedProfile()
      }
    } message: {
      Text(deleteConfirmationMessage)
    }
  }

  private var profileList: some View {
    VStack(spacing: 0) {
      List(selection: $selectedProfileID) {
        ForEach(model.profiles) { profile in
          HStack(spacing: 8) {
            Text(profile.name)
              .lineLimit(1)
            Spacer(minLength: 4)
            if profile.id == model.envelope.activeProfileID {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(StudioDesign.accent)
                .help("Active Profile")
            }
          }
          .tag(profile.id)
        }
      }
      .listStyle(.sidebar)
      .accessibilityLabel("Profiles")

      Divider()

      HStack(spacing: 8) {
        Button {
          model.createProfile()
        } label: {
          Image(systemName: "plus")
        }
        .help("New Profile")

        Button {
          duplicateSelectedProfile()
        } label: {
          Image(systemName: "plus.square.on.square")
        }
        .help("Duplicate Profile")
        .disabled(selectedProfile == nil)

        Spacer()

        Menu {
          Button("Rename…") {
            beginRename()
          }
          Button("Delete…", role: .destructive) {
            showsDeleteConfirmation = true
          }
          .disabled(model.profiles.count <= 1)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("Profile Actions")
        .disabled(selectedProfile == nil)
      }
      .buttonStyle(.borderless)
      .padding(12)
    }
    .frame(width: 225)
  }

  /// Builds the selected Profile's complete editor.
  private func profileEditor(_ profile: Profile) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        profileHeader(profile)

        if let notice = model.lastError {
          NoticeBanner(
            message: notice,
            dismiss: model.clearNotice
          )
        }

        ForEach(model.supportedDeviceDescriptors, id: \.modelID) {
          descriptor in
          deviceSection(profile: profile, descriptor: descriptor)
        }
      }
      .padding(28)
      .frame(maxWidth: 980)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .scrollIndicators(.hidden)
  }

  /// Builds the selected work mode's identity and activation controls.
  private func profileHeader(_ profile: Profile) -> some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 9) {
          Text(profile.name)
            .font(.largeTitle.weight(.semibold))
          if profile.id == model.envelope.activeProfileID {
            StatusPill(
              title: "Active",
              systemImage: "checkmark.circle.fill",
              color: StudioDesign.accent
            )
          }
        }
        Text(
          "Configure how each connected Device behaves in this work mode."
        )
        .foregroundStyle(.secondary)
      }

      Spacer()

      if profile.id != model.envelope.activeProfileID {
        Button("Make Active") {
          model.activateProfile(id: profile.id)
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  /// Builds one configured or safely inert Device section.
  @ViewBuilder
  private func deviceSection(
    profile: Profile,
    descriptor: DeviceModelDescriptor
  ) -> some View {
    let matchRule = DeviceMatchRule(modelID: descriptor.modelID)
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(descriptor.name)
            .font(.title3.weight(.semibold))
          Text(deviceSetupDetail(for: descriptor))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if let configuration = profile.configuration(
          matching: matchRule
        ) {
          Button("Remove Setup", role: .destructive) {
            model.removeDeviceConfiguration(
              profileID: profile.id,
              configurationID: configuration.id
            )
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.red)
        }
      }

      if let configuration = profile.configuration(
        matching: matchRule
      ) {
        DeviceBindingEditor(
          model: model,
          descriptor: descriptor,
          profileID: profile.id,
          configurationID: configuration.id
        )
      } else {
        HStack(spacing: 14) {
          Image(systemName: "minus.circle")
            .font(.title2)
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 3) {
            Text("Not configured in this Profile")
              .font(.headline)
            Text("Every Control safely resolves to No Action.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Add Device Setup") {
            model.addDeviceConfiguration(
              profileID: profile.id,
              descriptor: descriptor
            )
          }
        }
        .padding(16)
        .studioCard()
      }
    }
  }

  private var selectedProfile: Profile? {
    guard let selectedProfileID else {
      return nil
    }
    return model.envelope.profile(id: selectedProfileID)
  }

  private var replacementProfile: Profile? {
    model.profiles.first { $0.id != selectedProfileID }
  }

  private var deleteConfirmationMessage: String {
    guard selectedProfile?.id == model.envelope.activeProfileID,
      let replacementProfile
    else {
      return "This permanently removes its Device setups and Bindings."
    }
    return
      "This permanently removes its Device setups and Bindings. \(replacementProfile.name) will become active."
  }

  /// Starts rename with the selected Profile's current name.
  private func beginRename() {
    guard let selectedProfile else {
      return
    }
    renameDraft = selectedProfile.name
    showsRename = true
  }

  /// Duplicates the selected work mode.
  private func duplicateSelectedProfile() {
    guard let selectedProfileID else {
      return
    }
    model.duplicateProfile(id: selectedProfileID)
  }

  /// Deletes the selected Profile with a deterministic replacement.
  private func deleteSelectedProfile() {
    guard let selectedProfileID else {
      return
    }
    model.deleteProfile(
      id: selectedProfileID,
      replacementProfileID: replacementProfile?.id
    )
  }

  /// Selects newly created Profiles and repairs stale selections.
  private func reconcileSelection(
    previousIDs: [UUID],
    currentIDs: [UUID]
  ) {
    let inserted = currentIDs.first { !previousIDs.contains($0) }
    if let inserted {
      selectedProfileID = inserted
    } else if let selectedProfileID,
      currentIDs.contains(selectedProfileID)
    {
      self.selectedProfileID = selectedProfileID
    } else {
      selectedProfileID = model.envelope.activeProfileID
    }
  }

  /// Explains whether indistinguishable connected Devices share this setup.
  private func deviceSetupDetail(
    for descriptor: DeviceModelDescriptor
  ) -> String {
    let matchingCount = model.connectedDevices.filter {
      $0.model.modelID == descriptor.modelID
    }.count
    if matchingCount > 1 {
      return
        "Shared by \(matchingCount) connected units because this model has no stable per-unit identifier."
    }
    return "Applies whenever this Device model is connected."
  }
}
