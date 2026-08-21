import Foundation
import HardwareControllerCore
import IOKit
import IOKit.hid

/// Discovers VEC devices and translates HID button elements on a private queue.
public final class InfinityHIDManager:
  HardwareInputSource,
  @unchecked Sendable
{
  public let deviceDescriptor = Infinity3Driver.descriptor

  private let queue: DispatchQueue
  private let onConnect: @Sendable (HardwareDeviceConnection) -> Void
  private let onDisconnect: @Sendable (DeviceID) -> Void
  private let onEvent: @Sendable (ControlEvent) -> Void
  private let operations: HIDManagerOperations

  private var lifetime: HIDManagerLifetime?
  private var isStarted = false

  public convenience init(
    queue: DispatchQueue,
    onConnect: @escaping @Sendable (HardwareDeviceConnection) -> Void,
    onDisconnect: @escaping @Sendable (DeviceID) -> Void,
    onEvent: @escaping @Sendable (ControlEvent) -> Void
  ) {
    self.init(
      queue: queue,
      onConnect: onConnect,
      onDisconnect: onDisconnect,
      onEvent: onEvent,
      operations: .live
    )
  }

  init(
    queue: DispatchQueue,
    onConnect: @escaping @Sendable (HardwareDeviceConnection) -> Void,
    onDisconnect: @escaping @Sendable (DeviceID) -> Void,
    onEvent: @escaping @Sendable (ControlEvent) -> Void,
    operations: HIDManagerOperations
  ) {
    self.queue = queue
    self.onConnect = onConnect
    self.onDisconnect = onDisconnect
    self.onEvent = onEvent
    self.operations = operations
  }

  public func start() -> HardwareInputStartResult {
    guard !isStarted else {
      return .started
    }

    let manager = IOHIDManagerCreate(
      kCFAllocatorDefault,
      IOOptionBits(kIOHIDOptionsTypeNone)
    )

    let matching: [String: Any] = [
      kIOHIDVendorIDKey: Infinity3Driver.vendorID,
      kIOHIDProductIDKey: Infinity3Driver.productID,
      kIOHIDPrimaryUsagePageKey: Infinity3Driver.usagePage,
      kIOHIDPrimaryUsageKey: Infinity3Driver.usage,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

    let context = Unmanaged.passUnretained(self).toOpaque()
    IOHIDManagerRegisterDeviceMatchingCallback(
      manager,
      Self.deviceMatched,
      context
    )
    IOHIDManagerRegisterDeviceRemovalCallback(
      manager,
      Self.deviceRemoved,
      context
    )
    IOHIDManagerRegisterInputValueCallback(
      manager,
      Self.inputValueReceived,
      context
    )
    let openResult = operations.open(
      manager,
      IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
    )
    guard openResult == kIOReturnSuccess else {
      return .failed(Self.startFailure(for: openResult))
    }

    let lifetime = HIDManagerLifetime(manager: manager)
    operations.setDispatchQueue(manager, queue)
    operations.setCancelHandler(manager) {
      lifetime.releaseManager()
    }
    self.lifetime = lifetime
    isStarted = true
    operations.activate(manager)
    return .started
  }

  public func stop() {
    guard
      let manager = lifetime?.manager,
      isStarted
    else {
      return
    }

    _ = operations.close(
      manager,
      IOOptionBits(kIOHIDOptionsTypeNone)
    )
    operations.cancel(manager)
    lifetime = nil
    isStarted = false
  }

  private static func startFailure(
    for result: IOReturn
  ) -> HardwareInputStartFailure {
    switch result {
    case kIOReturnExclusiveAccess:
      .exclusiveAccess
    case kIOReturnNotPermitted:
      .notPermitted
    default:
      .system(code: result)
    }
  }

  private func didMatch(_ device: IOHIDDevice) {
    onConnect(
      HardwareDeviceConnection(
        id: deviceID(for: device),
        name:
          stringProperty(
            kIOHIDProductKey,
            from: device
          ) ?? deviceDescriptor.name,
        model: deviceDescriptor
      )
    )
  }

  private func didRemove(_ device: IOHIDDevice) {
    onDisconnect(deviceID(for: device))
  }

  private func didReceive(_ value: IOHIDValue) {
    let element = IOHIDValueGetElement(value)
    guard
      IOHIDElementGetUsagePage(element) == kHIDPage_Button,
      let controlID = Infinity3Driver.controlID(
        forButtonUsage: IOHIDElementGetUsage(element)
      )
    else {
      return
    }

    let device = IOHIDElementGetDevice(element)
    onEvent(
      ControlEvent(
        deviceID: deviceID(for: device),
        controlID: controlID,
        phase: IOHIDValueGetIntegerValue(value) == 0
          ? .released : .pressed,
        timestampNanoseconds:
          MonotonicClock.nanoseconds(
            fromAbsoluteTicks:
              IOHIDValueGetTimeStamp(value)
          )
      )
    )
  }

  private func deviceID(for device: IOHIDDevice) -> DeviceID {
    if let serial = stringProperty(
      kIOHIDSerialNumberKey,
      from: device
    ), !serial.isEmpty {
      return DeviceID(rawValue: "vec-\(serial)")
    }

    let location =
      numberProperty(kIOHIDLocationIDKey, from: device)?.uint64Value
      ?? 0
    let registryID =
      numberProperty(kIOHIDUniqueIDKey, from: device)?.uint64Value
      ?? 0
    return DeviceID(
      rawValue: String(
        format: "vec-%08llx-%016llx",
        location,
        registryID
      )
    )
  }

  private func stringProperty(
    _ key: String,
    from device: IOHIDDevice
  ) -> String? {
    IOHIDDeviceGetProperty(device, key as CFString) as? String
  }

  private func numberProperty(
    _ key: String,
    from device: IOHIDDevice
  ) -> NSNumber? {
    IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber
  }

  private static let deviceMatched: IOHIDDeviceCallback = {
    context,
    _,
    _,
    device in
    guard let context else {
      return
    }
    Unmanaged<InfinityHIDManager>
      .fromOpaque(context)
      .takeUnretainedValue()
      .didMatch(device)
  }

  private static let deviceRemoved: IOHIDDeviceCallback = {
    context,
    _,
    _,
    device in
    guard let context else {
      return
    }
    Unmanaged<InfinityHIDManager>
      .fromOpaque(context)
      .takeUnretainedValue()
      .didRemove(device)
  }

  private static let inputValueReceived: IOHIDValueCallback = {
    context,
    _,
    _,
    value in
    guard let context else {
      return
    }
    Unmanaged<InfinityHIDManager>
      .fromOpaque(context)
      .takeUnretainedValue()
      .didReceive(value)
  }
}

final class HIDManagerLifetime: @unchecked Sendable {
  private(set) var manager: IOHIDManager?

  init(manager: IOHIDManager) {
    self.manager = manager
  }

  func releaseManager() {
    manager = nil
  }
}

struct HIDManagerOperations: @unchecked Sendable {
  let open: (IOHIDManager, IOOptionBits) -> IOReturn
  let close: (IOHIDManager, IOOptionBits) -> IOReturn
  let setDispatchQueue: (IOHIDManager, DispatchQueue) -> Void
  let setCancelHandler:
    (
      IOHIDManager,
      @escaping @Sendable () -> Void
    ) -> Void
  let activate: (IOHIDManager) -> Void
  let cancel: (IOHIDManager) -> Void

  static let live = HIDManagerOperations(
    open: IOHIDManagerOpen,
    close: IOHIDManagerClose,
    setDispatchQueue: IOHIDManagerSetDispatchQueue,
    setCancelHandler: IOHIDManagerSetCancelHandler,
    activate: IOHIDManagerActivate,
    cancel: IOHIDManagerCancel
  )
}
