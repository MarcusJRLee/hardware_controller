import Foundation

/// Names the Binding a Profile edit changes.
public enum ProfileBindingTarget: Equatable, Sendable {
  /// The active Profile's setup for the context's primary Device model.
  case active(ControlID)
  /// One identified Profile setup, active or not.
  case identified(ControlID, profileID: UUID, configurationID: UUID)
}

/// One change to a single Binding.
public enum BindingEdit: Equatable, Sendable {
  case action(ActionKind)
  case interactionMode(InteractionMode)
  case shortcut(KeyboardShortcut)
  case activationShortcut(KeyboardShortcut?)
}

/// One user-requested change to the persisted Profile collection.
public enum ProfileEdit: Equatable, Sendable {
  case binding(BindingEdit, ProfileBindingTarget)
  case createProfile
  case duplicateProfile(id: UUID)
  case renameProfile(id: UUID, name: String)
  case deleteProfile(id: UUID, replacementProfileID: UUID?)
  case activateProfile(id: UUID)
  case addDeviceConfiguration(profileID: UUID, descriptor: DeviceModelDescriptor)
  case removeDeviceConfiguration(profileID: UUID, configurationID: UUID)
}

/// Explains why a Profile edit was rejected against the current envelope.
public enum ProfileEditFailure: Error, Equatable, Sendable {
  case profileMissing
  case deviceConfigurationMissing
  case bindingMissing
  case activationShortcutNeedsAction
  case deletionRejected
}

/// Runtime facts an edit needs that the envelope does not hold.
public struct ProfileEditContext: Equatable, Sendable {
  public let primaryModelID: DeviceModelID
  /// Connected Device models, which seed a new Profile's inert setups.
  public let connectedDevices: [DeviceModelDescriptor]

  public init(primaryModelID: DeviceModelID, connectedDevices: [DeviceModelDescriptor]) {
    self.primaryModelID = primaryModelID
    self.connectedDevices = connectedDevices
  }
}

/// The envelope to commit and the Profile the runtime must adopt, if any.
public struct ProfileEditResult: Equatable, Sendable {
  public let envelope: ProfileEnvelope
  /// Nil when the active Profile's runtime behavior is unchanged.
  public let runtimeProfile: Profile?
}

/// The suggested shortcut when a Binding first becomes a keyboard shortcut.
private let defaultKeyboardShortcut = KeyboardShortcut(keyCode: 15, modifiers: [.command])

extension ProfileEnvelope {
  /// Applies one edit as a pure transformation; nil means nothing changes.
  public func applying(
    _ edit: ProfileEdit,
    in context: ProfileEditContext
  ) throws(ProfileEditFailure) -> ProfileEditResult? {
    switch edit {
    case .binding(let change, let target):
      return try applying(change, to: target, primaryModelID: context.primaryModelID)
    case .createProfile:
      var candidate = self
      candidate.profiles.append(
        Profile.safeProfile(
          name: uniqueName(base: "New Profile"),
          deviceDescriptors: context.connectedDevices
        )
      )
      return ProfileEditResult(envelope: candidate, runtimeProfile: nil)
    case .duplicateProfile(let id):
      let source = try existingProfile(id)
      var candidate = self
      candidate.profiles.append(
        source.duplicated(name: uniqueName(base: "\(source.name) Copy"))
      )
      return ProfileEditResult(envelope: candidate, runtimeProfile: nil)
    case .renameProfile(let id, let name):
      var profile = try existingProfile(id)
      profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      var candidate = self
      candidate.setProfile(profile)
      return ProfileEditResult(envelope: candidate, runtimeProfile: nil)
    case .deleteProfile(let id, let replacementProfileID):
      var candidate = self
      do {
        try candidate.removeProfile(id: id, replacementProfileID: replacementProfileID)
      } catch {
        throw .deletionRejected
      }
      return ProfileEditResult(
        envelope: candidate,
        runtimeProfile: activeProfileID == id ? candidate.activeProfile : nil
      )
    case .activateProfile(let id):
      let profile = try existingProfile(id)
      guard id != activeProfileID else {
        return nil
      }
      var candidate = self
      candidate.activeProfileID = id
      return ProfileEditResult(envelope: candidate, runtimeProfile: profile)
    case .addDeviceConfiguration(let profileID, let descriptor):
      var profile = try existingProfile(profileID)
      guard profile.configuration(matching: DeviceMatchRule(modelID: descriptor.modelID)) == nil
      else {
        return nil
      }
      profile.setDeviceConfiguration(Profile.safeDeviceConfiguration(for: descriptor))
      return replacing(profile)
    case .removeDeviceConfiguration(let profileID, let configurationID):
      var profile = try existingProfile(profileID)
      guard profile.deviceConfigurations.contains(where: { $0.id == configurationID }) else {
        throw .deviceConfigurationMissing
      }
      profile.removeDeviceConfiguration(id: configurationID)
      return replacing(profile)
    }
  }

  private func applying(
    _ change: BindingEdit,
    to target: ProfileBindingTarget,
    primaryModelID: DeviceModelID
  ) throws(ProfileEditFailure) -> ProfileEditResult {
    let (controlID, profileID, configurationID) = try resolve(
      target, primaryModelID: primaryModelID)
    guard
      var profile = profile(id: profileID),
      let configurationIndex = profile.deviceConfigurations.firstIndex(
        where: { $0.id == configurationID }
      ),
      var binding = profile.deviceConfigurations[configurationIndex].binding(for: controlID)
    else {
      throw .bindingMissing
    }
    switch change {
    case .action(.noAction):
      binding.action = .noAction
      binding.activationShortcut = nil
    case .action(.dictation):
      binding.action = .dictation()
    case .action(.localAIDictation):
      binding.action = .localAIDictation()
    case .action(.askGemini):
      binding.action = .askGemini()
    case .action(.keyboardShortcut):
      binding.action = .keyboardShortcut(binding.action.shortcut ?? defaultKeyboardShortcut)
    case .interactionMode(let mode):
      binding.interactionMode = mode
    case .shortcut(let shortcut):
      binding.action.shortcut = shortcut
    case .activationShortcut(let shortcut):
      // A fallback without an Action would register a key that does nothing.
      guard binding.action.kind != .noAction || shortcut == nil else {
        throw .activationShortcutNeedsAction
      }
      binding.activationShortcut = shortcut
    }
    profile.deviceConfigurations[configurationIndex].setBinding(binding)
    return replacing(profile)
  }

  /// Resolves an active-setup target against the current active Profile.
  private func resolve(
    _ target: ProfileBindingTarget,
    primaryModelID: DeviceModelID
  ) throws(ProfileEditFailure) -> (ControlID, UUID, UUID) {
    switch target {
    case .identified(let controlID, let profileID, let configurationID):
      return (controlID, profileID, configurationID)
    case .active(let controlID):
      guard
        let profile = activeProfile,
        let configuration = profile.configuration(
          matching: DeviceMatchRule(modelID: primaryModelID))
      else {
        throw .deviceConfigurationMissing
      }
      return (controlID, profile.id, configuration.id)
    }
  }

  private func existingProfile(_ id: UUID) throws(ProfileEditFailure) -> Profile {
    guard let profile = profile(id: id) else {
      throw .profileMissing
    }
    return profile
  }

  /// Replaces one Profile; the runtime adopts it only when it is active.
  private func replacing(_ profile: Profile) -> ProfileEditResult {
    var candidate = self
    candidate.setProfile(profile)
    return ProfileEditResult(
      envelope: candidate,
      runtimeProfile: profile.id == activeProfileID ? profile : nil
    )
  }
}
