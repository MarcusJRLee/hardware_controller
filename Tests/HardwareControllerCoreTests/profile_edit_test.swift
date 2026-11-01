import Foundation
import Testing

@testable import HardwareControllerCore

struct ProfileEditTest {
  private let context = ProfileEditContext(
    primaryModelID: .vecInfinity3,
    connectedDevices: [Infinity3Driver.descriptor]
  )
  private let envelope = ProfileEnvelope.defaultEnvelope()

  private var active: Profile {
    get throws { try #require(envelope.activeProfile) }
  }

  private func apply(
    _ edit: ProfileEdit,
    to envelope: ProfileEnvelope? = nil
  ) throws -> ProfileEditResult? {
    try (envelope ?? self.envelope).applying(edit, in: context)
  }

  private func binding(_ controlID: ControlID, in result: ProfileEditResult?) throws -> Binding {
    try #require(
      result?.envelope.activeProfile?.binding(
        for: controlID,
        matching: DeviceMatchRule(modelID: .vecInfinity3)
      )
    )
  }

  /// Each Binding edit changes only its field and reaches the runtime.
  @Test
  func bindingEditsChangeOneFieldOfTheActiveSetup() throws {
    let shortcut = KeyboardShortcut(keyCode: 1, modifiers: [.option])
    let cases: [(BindingEdit, (Binding) -> Bool)] = [
      (
        .action(.keyboardShortcut),
        { $0.action.shortcut == KeyboardShortcut(keyCode: 15, modifiers: [.command]) }
      ),
      (.interactionMode(.toggle), { $0.interactionMode == .toggle }),
      (.shortcut(shortcut), { $0.action.shortcut == shortcut }),
    ]
    for (change, holds) in cases {
      let result = try apply(.binding(change, .active(.left)))
      #expect(holds(try binding(.left, in: result)))
      #expect(
        try binding(.center, in: result)
          == active.binding(for: .center, matching: DeviceMatchRule(modelID: .vecInfinity3)))
      #expect(result?.runtimeProfile == result?.envelope.activeProfile)
    }
  }

  /// Clearing an Action also clears its keyboard fallback.
  @Test
  func noActionClearsTheFallbackAndFallbacksNeedAnAction() throws {
    let withFallback = try apply(
      .binding(.activationShortcut(.suggestedControlActivation), .active(.center))
    )
    #expect(
      try binding(.center, in: withFallback).activationShortcut == .suggestedControlActivation)
    let cleared = try apply(
      .binding(.action(.noAction), .active(.center)), to: withFallback?.envelope)
    #expect(try binding(.center, in: cleared).activationShortcut == nil)
    #expect(throws: ProfileEditFailure.activationShortcutNeedsAction) {
      try apply(.binding(.activationShortcut(.suggestedControlActivation), .active(.left)))
    }
  }

  /// Inactive edits persist without touching the running Profile.
  @Test
  func inactiveProfileEditsDoNotReachTheRuntime() throws {
    let created = try #require(try apply(.createProfile))
    let inactive = try #require(created.envelope.profiles.last)
    let configuration = try #require(inactive.deviceConfigurations.first)
    let edited = try apply(
      .binding(
        .action(.dictation),
        .identified(.left, profileID: inactive.id, configurationID: configuration.id)
      ),
      to: created.envelope
    )
    #expect(inactive.name == "New Profile")
    #expect(created.runtimeProfile == nil)
    #expect(edited?.runtimeProfile == nil)
    #expect(
      edited?.envelope.profile(id: inactive.id)?.deviceConfigurations.first?.binding(for: .left)?
        .action == .dictation())
  }

  /// Stale identities fail with the specific missing piece.
  @Test
  func staleIdentitiesFailWithTypedReasons() throws {
    let missing = UUID()
    let cases: [(ProfileEdit, ProfileEditFailure)] = [
      (.duplicateProfile(id: missing), .profileMissing),
      (.renameProfile(id: missing, name: "x"), .profileMissing),
      (.activateProfile(id: missing), .profileMissing),
      (.deleteProfile(id: try active.id, replacementProfileID: nil), .deletionRejected),
      (
        .removeDeviceConfiguration(profileID: try active.id, configurationID: missing),
        .deviceConfigurationMissing
      ),
      (
        .binding(
          .action(.dictation), .identified(.left, profileID: missing, configurationID: missing)),
        .bindingMissing
      ),
    ]
    for (edit, failure) in cases {
      #expect(throws: failure) { try apply(edit) }
    }
    let unmatched = ProfileEditContext(
      primaryModelID: DeviceModelID(rawValue: "other"), connectedDevices: [])
    #expect(throws: ProfileEditFailure.deviceConfigurationMissing) {
      try envelope.applying(.binding(.action(.dictation), .active(.left)), in: unmatched)
    }
  }

  /// Profile lifecycle edits keep names unique and the active selection valid.
  @Test
  func profileLifecycleKeepsTheActiveSelectionValid() throws {
    let renamed = try #require(try apply(.renameProfile(id: try active.id, name: "  Coding  ")))
    let duplicated = try #require(
      try apply(.duplicateProfile(id: try active.id), to: renamed.envelope))
    let copy = try #require(duplicated.envelope.profiles.last)
    #expect(duplicated.envelope.profiles.map(\.name) == ["Coding", "Coding Copy"])
    #expect(try apply(.activateProfile(id: try active.id), to: duplicated.envelope) == nil)

    let activated = try #require(try apply(.activateProfile(id: copy.id), to: duplicated.envelope))
    #expect(activated.runtimeProfile == copy)
    let deleted = try #require(
      try apply(
        .deleteProfile(id: copy.id, replacementProfileID: try active.id), to: activated.envelope)
    )
    #expect(deleted.envelope.activeProfileID == (try active.id))
    #expect(deleted.runtimeProfile == renamed.envelope.activeProfile)
  }

  /// Device setups are added once and removed explicitly.
  @Test
  func deviceSetupsAreAddedOnceAndRemovedExplicitly() throws {
    let profile = try active
    let configuration = try #require(profile.deviceConfigurations.first)
    #expect(
      try apply(
        .addDeviceConfiguration(profileID: profile.id, descriptor: Infinity3Driver.descriptor))
        == nil)
    let removed = try #require(
      try apply(
        .removeDeviceConfiguration(profileID: profile.id, configurationID: configuration.id))
    )
    #expect(removed.runtimeProfile?.deviceConfigurations.isEmpty == true)
    let restored = try apply(
      .addDeviceConfiguration(profileID: profile.id, descriptor: Infinity3Driver.descriptor),
      to: removed.envelope
    )
    #expect(restored?.runtimeProfile?.deviceConfigurations.count == 1)
  }
}
