import Foundation

/// Stores one Device setup inside a Profile.
public struct ProfileDeviceConfiguration:
  Equatable,
  Codable,
  Identifiable,
  Sendable
{
  public let id: UUID
  public var matchRule: DeviceMatchRule
  public var bindings: [Binding]

  public init(
    id: UUID = UUID(),
    matchRule: DeviceMatchRule,
    bindings: [Binding]
  ) {
    self.id = id
    self.matchRule = matchRule
    self.bindings = bindings
  }

  /// Returns the Binding for one Driver-defined Control.
  public func binding(for controlID: ControlID) -> Binding? {
    bindings.first { $0.controlID == controlID }
  }

  /// Inserts or replaces one Control Binding.
  public mutating func setBinding(_ binding: Binding) {
    if let index = bindings.firstIndex(
      where: { $0.controlID == binding.controlID }
    ) {
      bindings[index] = binding
    } else {
      bindings.append(binding)
    }
  }
}

/// Identifies a failed Profile mutation without hiding invalid state.
public enum ProfileMutationError: Error, Equatable, Sendable {
  case deviceConfigurationMissing(UUID)
  case profileMissing(UUID)
  case cannotDeleteLastProfile
  case replacementProfileMissing(UUID)
}

/// Stores one named work mode and its independent Device setups.
public struct Profile: Equatable, Codable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var deviceConfigurations: [ProfileDeviceConfiguration]

  public init(
    id: UUID = UUID(),
    name: String,
    deviceConfigurations: [ProfileDeviceConfiguration]
  ) {
    self.id = id
    self.name = name
    self.deviceConfigurations = deviceConfigurations
  }

  /// Returns the most-specific Device configuration for a connection.
  public func configuration(
    matching device: DeviceMatchRule
  ) -> ProfileDeviceConfiguration? {
    if device.stableHardwareID != nil,
      let exact = deviceConfigurations.first(
        where: { $0.matchRule == device }
      )
    {
      return exact
    }
    return deviceConfigurations.first {
      $0.matchRule.modelID == device.modelID
        && $0.matchRule.stableHardwareID == nil
    }
  }

  /// Returns one Binding through the Device match boundary.
  public func binding(
    for controlID: ControlID,
    matching device: DeviceMatchRule
  ) -> Binding? {
    configuration(matching: device)?.binding(for: controlID)
  }

  /// Inserts or replaces one Binding in an identified Device setup.
  public mutating func setBinding(
    _ binding: Binding,
    configurationID: UUID
  ) throws {
    guard
      let index = deviceConfigurations.firstIndex(
        where: { $0.id == configurationID }
      )
    else {
      throw ProfileMutationError.deviceConfigurationMissing(
        configurationID
      )
    }
    deviceConfigurations[index].setBinding(binding)
  }

  /// Inserts or replaces one complete Device setup.
  public mutating func setDeviceConfiguration(
    _ configuration: ProfileDeviceConfiguration
  ) {
    if let index = deviceConfigurations.firstIndex(
      where: { $0.id == configuration.id }
    ) {
      deviceConfigurations[index] = configuration
    } else {
      deviceConfigurations.append(configuration)
    }
  }

  /// Removes one Device setup and leaves unmatched Devices inert.
  public mutating func removeDeviceConfiguration(id: UUID) {
    deviceConfigurations.removeAll { $0.id == id }
  }

  /// Creates a safe No Action setup from Driver metadata.
  public static func safeDeviceConfiguration(
    for descriptor: DeviceModelDescriptor
  ) -> ProfileDeviceConfiguration {
    ProfileDeviceConfiguration(
      matchRule: DeviceMatchRule(modelID: descriptor.modelID),
      bindings: descriptor.controls.map {
        Binding(
          controlID: $0.id,
          interactionMode: .momentary,
          action: .noAction
        )
      }
    )
  }

  /// Copies a complete work mode with fresh persistent identities.
  public func duplicated(
    id: UUID = UUID(),
    name: String
  ) -> Profile {
    Profile(
      id: id,
      name: name,
      deviceConfigurations: deviceConfigurations.map { configuration in
        ProfileDeviceConfiguration(
          matchRule: configuration.matchRule,
          bindings: configuration.bindings
        )
      }
    )
  }

  /// Creates an inert work mode for each unique Device model.
  public static func safeProfile(
    name: String,
    deviceDescriptors: [DeviceModelDescriptor]
  ) -> Profile {
    var modelIDs: Set<DeviceModelID> = []
    let configurations: [ProfileDeviceConfiguration] =
      deviceDescriptors.compactMap { descriptor in
        guard modelIDs.insert(descriptor.modelID).inserted else {
          return nil
        }
        return safeDeviceConfiguration(for: descriptor)
      }
    return Profile(
      name: name,
      deviceConfigurations: configurations
    )
  }

  // swift-format-ignore: DontRepeatTypeInStaticProperties
  public static let defaultProfile = Profile(
    name: "Default",
    deviceConfigurations: [
      ProfileDeviceConfiguration(
        matchRule: DeviceMatchRule(modelID: .vecInfinity3),
        bindings: [
          Binding(
            controlID: .left,
            interactionMode: .momentary,
            action: .noAction
          ),
          Binding(
            controlID: .center,
            interactionMode: .momentary,
            action: .dictation()
          ),
          Binding(
            controlID: .right,
            interactionMode: .momentary,
            action: .noAction
          ),
        ]
      )
    ]
  )
}

/// Resolves one immutable active Profile without persistence or UI work.
public struct ProfileBindingResolver: Sendable {
  private struct ResolvedBinding: Sendable {
    let targetID: BindingTargetID
    let binding: Binding
  }

  private let bindingsByMatchRule: [DeviceMatchRule: [ControlID: ResolvedBinding]]
  private let bindingsByTargetID: [BindingTargetID: Binding]
  public let keyboardFallbacks: [KeyboardFallbackRegistration]

  public init(profile: Profile) {
    bindingsByMatchRule = Dictionary(
      profile.deviceConfigurations.map { configuration in
        (
          configuration.matchRule,
          Dictionary(
            configuration.bindings.map { binding in
              let targetID = BindingTargetID(
                configurationID: configuration.id,
                controlID: binding.controlID
              )
              return (
                binding.controlID,
                ResolvedBinding(
                  targetID: targetID,
                  binding: binding
                )
              )
            },
            uniquingKeysWith: { existing, _ in existing }
          )
        )
      },
      uniquingKeysWith: { existing, _ in existing }
    )
    bindingsByTargetID = Dictionary(
      profile.deviceConfigurations.flatMap { configuration in
        configuration.bindings.map { binding in
          (
            BindingTargetID(
              configurationID: configuration.id,
              controlID: binding.controlID
            ),
            binding
          )
        }
      },
      uniquingKeysWith: { existing, _ in existing }
    )
    keyboardFallbacks = profile.deviceConfigurations.flatMap {
      configuration in
      configuration.bindings.compactMap { binding in
        guard let shortcut = binding.activationShortcut else {
          return nil
        }
        let targetID = BindingTargetID(
          configurationID: configuration.id,
          controlID: binding.controlID
        )
        return KeyboardFallbackRegistration(
          targetID: targetID,
          sourceDeviceID: DeviceID(
            rawValue: "keyboard-fallback-\(configuration.id.uuidString.lowercased())"
          ),
          shortcut: shortcut
        )
      }
    }
  }

  /// Resolves the exact instance before the model-level fallback.
  public func resolvedBinding(
    for controlID: ControlID,
    matching device: DeviceMatchRule
  ) -> (targetID: BindingTargetID, binding: Binding)? {
    if device.stableHardwareID != nil,
      let exactBindings = bindingsByMatchRule[device]
    {
      return exactBindings[controlID].map {
        ($0.targetID, $0.binding)
      }
    }
    let modelRule = DeviceMatchRule(modelID: device.modelID)
    return bindingsByMatchRule[modelRule]?[controlID].map {
      ($0.targetID, $0.binding)
    }
  }

  /// Resolves one Binding through its persistent Profile target.
  public func binding(
    for targetID: BindingTargetID
  ) -> Binding? {
    bindingsByTargetID[targetID]
  }

  /// Preserves the existing Binding-only lookup for non-runtime callers.
  public func binding(
    for controlID: ControlID,
    matching device: DeviceMatchRule
  ) -> Binding? {
    resolvedBinding(for: controlID, matching: device)?.binding
  }
}

/// Stores all Profiles and the authoritative active work mode.
public struct ProfileEnvelope: Equatable, Codable, Sendable {
  public static let currentSchemaVersion = 5

  public var schemaVersion: Int
  public var activeProfileID: UUID
  public var profiles: [Profile]

  public init(
    schemaVersion: Int = currentSchemaVersion,
    activeProfileID: UUID,
    profiles: [Profile]
  ) {
    self.schemaVersion = schemaVersion
    self.activeProfileID = activeProfileID
    self.profiles = profiles
  }

  public var activeProfile: Profile? {
    profile(id: activeProfileID)
  }

  /// Returns one Profile by stable identity.
  public func profile(id: UUID) -> Profile? {
    profiles.first { $0.id == id }
  }

  /// Inserts or replaces one complete Profile.
  public mutating func setProfile(_ profile: Profile) {
    if let index = profiles.firstIndex(
      where: { $0.id == profile.id }
    ) {
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
  }

  /// Removes one Profile while preserving a valid active selection.
  public mutating func removeProfile(
    id: UUID,
    replacementProfileID: UUID?
  ) throws {
    guard profiles.contains(where: { $0.id == id }) else {
      throw ProfileMutationError.profileMissing(id)
    }
    guard profiles.count > 1 else {
      throw ProfileMutationError.cannotDeleteLastProfile
    }
    if activeProfileID == id {
      guard
        let replacementProfileID,
        replacementProfileID != id,
        profiles.contains(where: { $0.id == replacementProfileID })
      else {
        throw ProfileMutationError.replacementProfileMissing(
          replacementProfileID ?? id
        )
      }
      activeProfileID = replacementProfileID
    }
    profiles.removeAll { $0.id == id }
  }

  /// Returns a case-insensitively unique display name.
  public func uniqueName(base: String) -> String {
    let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
    let root = trimmed.isEmpty ? "Profile" : trimmed
    let existing = Set(profiles.map { $0.name.lowercased() })
    guard existing.contains(root.lowercased()) else {
      return root
    }
    var suffix = 2
    while existing.contains("\(root) \(suffix)".lowercased()) {
      suffix += 1
    }
    return "\(root) \(suffix)"
  }

  public static func defaultEnvelope() -> ProfileEnvelope {
    let profile = Profile.defaultProfile
    return ProfileEnvelope(
      activeProfileID: profile.id,
      profiles: [profile]
    )
  }
}
