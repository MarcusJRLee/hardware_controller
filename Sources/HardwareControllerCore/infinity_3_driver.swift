import Foundation

extension DeviceModelID {
  /// Identifies the supported VEC Infinity 3 model.
  public static let vecInfinity3 = DeviceModelID(
    rawValue: "vec_infinity_3"
  )
}

/// Maps one confirmed Infinity 3 Button element to one logical Control.
public struct Infinity3ButtonMapping: Equatable, Sendable {
  public let reportMask: UInt8
  public let usage: UInt32
  public let control: ControlDescriptor

  /// Creates one physically verifiable Button mapping.
  public init(
    reportMask: UInt8,
    usage: UInt32,
    control: ControlDescriptor
  ) {
    self.reportMask = reportMask
    self.usage = usage
    self.control = control
  }
}

public enum Infinity3Driver {
  public static let vendorID = 0x05F3
  public static let productID = 0x00FF
  public static let usagePage = 0x0C
  public static let usage = 0x03

  public static let buttonMappings = [
    Infinity3ButtonMapping(
      reportMask: 0b001,
      usage: 1,
      control: ControlDescriptor(id: .left, name: "Left")
    ),
    Infinity3ButtonMapping(
      reportMask: 0b010,
      usage: 2,
      control: ControlDescriptor(
        id: .center,
        name: "Center",
        visualWeight: .prominent
      ),
    ),
    Infinity3ButtonMapping(
      reportMask: 0b100,
      usage: 3,
      control: ControlDescriptor(id: .right, name: "Right")
    ),
  ]

  public static let descriptor = DeviceModelDescriptor(
    modelID: .vecInfinity3,
    name: "VEC Infinity 3",
    controls: buttonMappings.map(\.control)
  )

  public static let controls = descriptor.controls.map(\.id)

  /// Resolves a typed HID Button usage through the confirmed mapping.
  public static func controlID(
    forButtonUsage usage: UInt32
  ) -> ControlID? {
    buttonMappings.first { $0.usage == usage }?.control.id
  }
}

public enum Infinity3ReportError: Error, Equatable {
  case invalidLength(actual: Int)
}

/// Decodes the two-byte VEC report into deduplicated logical transitions.
public struct Infinity3ReportDecoder: Sendable {
  private var previousButtonMask: UInt8 = 0

  public init() {}

  public mutating func decode(
    _ report: [UInt8],
    deviceID: DeviceID,
    timestampNanoseconds: UInt64
  ) throws -> [ControlEvent] {
    guard report.count == 2 else {
      throw Infinity3ReportError.invalidLength(actual: report.count)
    }

    let buttonMask = report[0] & 0b0000_0111
    let changedMask = buttonMask ^ previousButtonMask
    previousButtonMask = buttonMask

    return Infinity3Driver.buttonMappings.compactMap { mapping in
      guard changedMask & mapping.reportMask != 0 else {
        return nil
      }
      return ControlEvent(
        deviceID: deviceID,
        controlID: mapping.control.id,
        phase:
          buttonMask & mapping.reportMask == 0
          ? .released : .pressed,
        timestampNanoseconds: timestampNanoseconds
      )
    }
  }
}
