import HardwareControllerCore

public enum HardwareInputStartFailure: Equatable, Sendable {
  case exclusiveAccess
  case notPermitted
  case system(code: Int32)

  public var recoveryMessage: String {
    switch self {
    case .exclusiveAccess:
      "Another copy of Hardware Controller or another hardware-control app is using the controller. Quit it, then retry."
    case .notPermitted:
      "macOS denied access to the controller. Reconnect it, then retry. If access remains blocked, review Privacy & Security settings."
    case .system(let code):
      "Controller input could not start because IOKit returned error \(code). Reconnect it, then retry."
    }
  }
}

public enum HardwareInputStartResult: Equatable, Sendable {
  case started
  case failed(HardwareInputStartFailure)
}

/// Describes one physical Device discovered by a hardware input source.
public struct HardwareDeviceConnection: Equatable, Sendable {
  public let id: DeviceID
  public let name: String
  public let model: DeviceModelDescriptor
  public let stableHardwareID: String?

  public init(
    id: DeviceID,
    name: String,
    model: DeviceModelDescriptor,
    stableHardwareID: String? = nil
  ) {
    self.id = id
    self.name = name
    self.model = model
    self.stableHardwareID = stableHardwareID
  }

  /// Returns the stable Profile match identity for this connection.
  public var matchRule: DeviceMatchRule {
    DeviceMatchRule(
      modelID: model.modelID,
      stableHardwareID: stableHardwareID
    )
  }
}

/// A lifecycle boundary for one hardware transport or driver composition.
public protocol HardwareInputSource: Sendable {
  var deviceDescriptor: DeviceModelDescriptor { get }

  @discardableResult
  func start() -> HardwareInputStartResult
  func stop()
}
