import Testing

@testable import HardwareControllerCore

struct ProfileTests {
  private let infinity = DeviceMatchRule(modelID: .vecInfinity3)

  /// Defines the safe three-Control default inside one Device setup.
  @Test
  func defaultProfileHasIndependentThreeControlBindings() throws {
    let profile = Profile.defaultProfile
    let configuration = try #require(
      profile.configuration(matching: infinity)
    )

    #expect(configuration.bindings.count == 3)
    #expect(profile.binding(for: .left, matching: infinity)?.action == .noAction)
    #expect(
      profile.binding(for: .center, matching: infinity)?.action.kind
        == .dictation
    )
    #expect(
      profile.binding(for: .center, matching: infinity)?.interactionMode
        == .momentary
    )
    #expect(
      profile.binding(for: .center, matching: infinity)?.action.shortcut
        == nil
    )
    #expect(profile.binding(for: .right, matching: infinity)?.action == .noAction)
  }

  /// Changes one Binding without mutating neighboring Controls.
  @Test
  func settingOneBindingPreservesTheOthers() throws {
    var profile = Profile.defaultProfile
    let configuration = try #require(
      profile.configuration(matching: infinity)
    )
    let leftBefore = profile.binding(for: .left, matching: infinity)
    let rightBefore = profile.binding(for: .right, matching: infinity)

    try profile.setBinding(
      Binding(
        controlID: .center,
        interactionMode: .toggle,
        action: .dictation()
      ),
      configurationID: configuration.id
    )

    #expect(profile.binding(for: .left, matching: infinity) == leftBefore)
    #expect(profile.binding(for: .right, matching: infinity) == rightBefore)
    #expect(
      profile.binding(for: .center, matching: infinity)?.interactionMode
        == .toggle
    )
  }

  /// Prefers a trustworthy unit setup over its model fallback.
  @Test
  func exactDeviceSetupOverridesModelSetup() {
    let exact = DeviceMatchRule(
      modelID: .vecInfinity3,
      stableHardwareID: "unit-1"
    )
    let profile = Profile(
      name: "Studio",
      deviceConfigurations: [
        ProfileDeviceConfiguration(
          matchRule: infinity,
          bindings: [Binding(controlID: .left, interactionMode: .momentary, action: .noAction)]
        ),
        ProfileDeviceConfiguration(
          matchRule: exact,
          bindings: [Binding(controlID: .left, interactionMode: .toggle, action: .dictation())]
        ),
      ]
    )

    #expect(
      profile.binding(for: .left, matching: exact)?.action.kind
        == .dictation
    )
    #expect(
      profile.binding(
        for: .left,
        matching: DeviceMatchRule(
          modelID: .vecInfinity3,
          stableHardwareID: "unit-2"
        )
      )?.action == .noAction
    )
  }

  /// Resolves immutable exact and model-level lookup safely.
  @Test
  func immutableResolverUsesSafeModelFallback() {
    let resolver = ProfileBindingResolver(profile: .defaultProfile)

    #expect(
      resolver.binding(
        for: .center,
        matching: DeviceMatchRule(
          modelID: .vecInfinity3,
          stableHardwareID: "unknown-unit"
        )
      )?.action.kind == .dictation
    )
    #expect(
      resolver.binding(
        for: .center,
        matching: DeviceMatchRule(
          modelID: DeviceModelID(rawValue: "other")
        )
      ) == nil
    )
  }

  /// Resolves an opt-in fallback without requiring a connected Device.
  @Test
  func resolverPublishesKeyboardFallbackTargets() throws {
    var profile = Profile.defaultProfile
    let configuration = try #require(profile.deviceConfigurations.first)
    var center = try #require(configuration.binding(for: .center))
    center.activationShortcut = .suggestedControlActivation
    try profile.setBinding(center, configurationID: configuration.id)

    let resolver = ProfileBindingResolver(profile: profile)
    let registration = try #require(resolver.keyboardFallbacks.first)

    #expect(resolver.keyboardFallbacks.count == 1)
    #expect(registration.targetID.configurationID == configuration.id)
    #expect(registration.targetID.controlID == .center)
    #expect(registration.shortcut == .suggestedControlActivation)
    #expect(
      resolver.binding(for: registration.targetID) == center
    )
  }

  /// Produces fresh IDs while preserving every copied Device Binding.
  @Test
  func duplicateProfileIsIndependent() throws {
    let original = Profile.defaultProfile
    let duplicate = original.duplicated(name: "Coding")

    #expect(duplicate.id != original.id)
    #expect(duplicate.name == "Coding")
    #expect(
      duplicate.deviceConfigurations.map(\.id)
        != original.deviceConfigurations.map(\.id)
    )
    #expect(
      duplicate.binding(for: .center, matching: infinity)
        == original.binding(for: .center, matching: infinity)
    )
  }

  /// Creates one inert setup per unique connected Device model.
  @Test
  func safeProfileDeduplicatesDeviceModels() throws {
    let profile = Profile.safeProfile(
      name: "Music",
      deviceDescriptors: [
        Infinity3Driver.descriptor,
        Infinity3Driver.descriptor,
      ]
    )
    let configuration = try #require(
      profile.configuration(matching: infinity)
    )

    #expect(profile.deviceConfigurations.count == 1)
    #expect(configuration.bindings.allSatisfy { $0.action == .noAction })
  }

  /// Preserves multiple Profiles and derives unique display names.
  @Test
  func envelopeKeepsMultiProfileShape() {
    let first = Profile.defaultProfile
    let second = Profile(name: "Logic", deviceConfigurations: [])
    let envelope = ProfileEnvelope(
      activeProfileID: second.id,
      profiles: [first, second]
    )

    #expect(envelope.activeProfile == second)
    #expect(envelope.schemaVersion == ProfileEnvelope.currentSchemaVersion)
    #expect(envelope.uniqueName(base: "Logic") == "Logic 2")
  }

  /// Requires an explicit valid replacement when deleting active state.
  @Test
  func deletingTheActiveProfileRequiresAValidReplacement() throws {
    let first = Profile.defaultProfile
    let second = Profile(name: "Music", deviceConfigurations: [])
    var envelope = ProfileEnvelope(
      activeProfileID: first.id,
      profiles: [first, second]
    )

    #expect(throws: ProfileMutationError.self) {
      try envelope.removeProfile(
        id: first.id,
        replacementProfileID: nil
      )
    }

    try envelope.removeProfile(
      id: first.id,
      replacementProfileID: second.id
    )
    #expect(envelope.activeProfile == second)
    #expect(envelope.profiles == [second])
  }
}
