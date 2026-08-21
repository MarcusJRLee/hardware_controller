import Foundation

/// Stable identity for one physical attachment.
public struct DeviceID: Hashable, Codable, Sendable, RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifies one Driver-defined Device model across reconnects.
public struct DeviceModelID:
  Hashable,
  Codable,
  Sendable,
  RawRepresentable
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Matches a Device model and, when trustworthy, one physical unit.
public struct DeviceMatchRule: Hashable, Codable, Sendable {
  public let modelID: DeviceModelID
  public let stableHardwareID: String?

  public init(
    modelID: DeviceModelID,
    stableHardwareID: String? = nil
  ) {
    self.modelID = modelID
    self.stableHardwareID = stableHardwareID
  }
}

/// Driver-defined identity for one independently actuated input.
public struct ControlID: Hashable, Codable, Sendable, RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let left = ControlID(rawValue: "left")
  public static let center = ControlID(rawValue: "center")
  public static let right = ControlID(rawValue: "right")
}

/// Controls how strongly a Driver emphasizes a Control in generic UI.
public enum ControlVisualWeight: String, Hashable, Sendable {
  case standard
  case prominent
}

/// Driver-supplied identity and presentation metadata for one Control.
public struct ControlDescriptor: Hashable, Sendable {
  public let id: ControlID
  public let name: String
  public let visualWeight: ControlVisualWeight

  public init(
    id: ControlID,
    name: String,
    visualWeight: ControlVisualWeight = .standard
  ) {
    self.id = id
    self.name = name
    self.visualWeight = visualWeight
  }
}

/// Driver-supplied capabilities and presentation metadata for one model.
public struct DeviceModelDescriptor: Equatable, Sendable {
  public let modelID: DeviceModelID
  public let name: String
  public let controls: [ControlDescriptor]

  public init(
    modelID: DeviceModelID,
    name: String,
    controls: [ControlDescriptor]
  ) {
    self.modelID = modelID
    self.name = name
    self.controls = controls
  }
}

public enum ControlPhase: String, Codable, Sendable {
  case pressed
  case released
}

/// A normalized hardware transition timestamped with a monotonic clock.
public struct ControlEvent: Equatable, Codable, Sendable {
  public let deviceID: DeviceID
  public let controlID: ControlID
  public let phase: ControlPhase
  public let timestampNanoseconds: UInt64

  public init(
    deviceID: DeviceID,
    controlID: ControlID,
    phase: ControlPhase,
    timestampNanoseconds: UInt64
  ) {
    self.deviceID = deviceID
    self.controlID = controlID
    self.phase = phase
    self.timestampNanoseconds = timestampNanoseconds
  }
}

public enum InteractionMode: String, CaseIterable, Codable, Sendable {
  case momentary
  case toggle
}

public enum KeyModifier: String, CaseIterable, Codable, Hashable, Sendable {
  case command
  case option
  case shift
  case control
  case function
}

public struct KeyboardShortcut: Equatable, Hashable, Codable, Sendable {
  public var keyCode: UInt16
  public var modifiers: Set<KeyModifier>

  public init(keyCode: UInt16, modifiers: Set<KeyModifier> = []) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  public static let legacyF5 = KeyboardShortcut(keyCode: 96)

  /// Avoids common macOS and VoiceOver shortcuts while remaining mnemonic.
  public static let suggestedControlActivation = KeyboardShortcut(
    keyCode: 2,
    modifiers: [.command, .shift, .control]
  )
}

public enum ActionKind: String, CaseIterable, Codable, Sendable {
  case noAction
  case dictation
  case localAIDictation
  case keyboardShortcut

  /// Identifies Actions that own the shared microphone lifecycle.
  public var ownsDictationSession: Bool {
    self == .dictation || self == .localAIDictation
  }
}

public struct ActionConfiguration: Equatable, Codable, Sendable {
  public var kind: ActionKind
  public var shortcut: KeyboardShortcut?

  public init(kind: ActionKind, shortcut: KeyboardShortcut? = nil) {
    self.kind = kind
    self.shortcut = shortcut
  }

  public static let noAction = ActionConfiguration(kind: .noAction)

  public static func dictation() -> ActionConfiguration {
    ActionConfiguration(kind: .dictation)
  }

  public static func localAIDictation() -> ActionConfiguration {
    ActionConfiguration(kind: .localAIDictation)
  }

  public static func keyboardShortcut(
    _ shortcut: KeyboardShortcut
  ) -> ActionConfiguration {
    ActionConfiguration(kind: .keyboardShortcut, shortcut: shortcut)
  }
}

public struct Binding: Equatable, Codable, Sendable {
  public var controlID: ControlID
  public var interactionMode: InteractionMode
  public var action: ActionConfiguration
  public var activationShortcut: KeyboardShortcut?

  public init(
    controlID: ControlID,
    interactionMode: InteractionMode,
    action: ActionConfiguration,
    activationShortcut: KeyboardShortcut? = nil
  ) {
    self.controlID = controlID
    self.interactionMode = interactionMode
    self.action = action
    self.activationShortcut = activationShortcut
  }
}

/// Identifies one logical Binding independently from its input source.
public struct BindingTargetID: Hashable, Sendable {
  public let configurationID: UUID
  public let controlID: ControlID

  public init(
    configurationID: UUID,
    controlID: ControlID
  ) {
    self.configurationID = configurationID
    self.controlID = controlID
  }
}

/// Registers one keyboard fallback against an active Profile Binding.
public struct KeyboardFallbackRegistration: Equatable, Sendable {
  public let targetID: BindingTargetID
  public let sourceDeviceID: DeviceID
  public let shortcut: KeyboardShortcut

  public init(
    targetID: BindingTargetID,
    sourceDeviceID: DeviceID,
    shortcut: KeyboardShortcut
  ) {
    self.targetID = targetID
    self.sourceDeviceID = sourceDeviceID
    self.shortcut = shortcut
  }
}

public enum ActionInvocationPhase: Equatable, Sendable {
  case begin
  case end
  case perform
}

public struct ActionInvocation: Equatable, Sendable {
  public let deviceID: DeviceID
  public let controlID: ControlID
  public let action: ActionConfiguration
  public let phase: ActionInvocationPhase
  public let inputTimestampNanoseconds: UInt64

  public init(
    deviceID: DeviceID,
    controlID: ControlID,
    action: ActionConfiguration,
    phase: ActionInvocationPhase,
    inputTimestampNanoseconds: UInt64
  ) {
    self.deviceID = deviceID
    self.controlID = controlID
    self.action = action
    self.phase = phase
    self.inputTimestampNanoseconds = inputTimestampNanoseconds
  }
}
