import Foundation
import HardwareControllerCore
import IOKit
import IOKit.hid
import Testing

@testable import HardwareControllerMac

struct Infinity3PhysicalCaptureTest {
  /// Captures sanitized raw reports and typed Button values from the real unit.
  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_CAPTURE_INFINITY_3_REPORTS"
        ] == "1"
    )
  )
  func capturesPhysicalReportsAndTypedValues() async throws {
    let duration =
      Int(
        ProcessInfo.processInfo.environment[
          "HC_CAPTURE_DURATION_SECONDS"
        ] ?? "45"
      ) ?? 45
    let recorder = Infinity3PhysicalRecorder()
    try recorder.start()
    for _ in 0..<30 where !recorder.hasMatchedDevice {
      try await Task.sleep(for: .milliseconds(100))
    }
    guard recorder.hasMatchedDevice else {
      recorder.stop()
      Issue.record("The exact Infinity 3 signature did not match.")
      return
    }
    print(
      "Infinity 3 matched. Capture sequence: left, center, right, each 10-second hold, every pair, then all three."
    )

    try await Task.sleep(for: .seconds(duration))
    recorder.stop()

    let capture = recorder.capture
    #expect(!capture.reports.isEmpty)
    #expect(
      Set(capture.values.map(\.usage))
        .isSuperset(of: [1, 2, 3])
    )
    print(capture.fixtureText)
  }
}

private struct Infinity3PhysicalCapture: Sendable {
  struct Report: Sendable {
    let timestamp: UInt64
    let bytes: [UInt8]
  }

  struct Value: Sendable {
    let timestamp: UInt64
    let usage: UInt32
    let integerValue: Int
  }

  let reports: [Report]
  let values: [Value]

  /// Formats relative, identifier-free data for source-controlled review.
  var fixtureText: String {
    let initialTimestamp =
      min(
        reports.first?.timestamp ?? .max,
        values.first?.timestamp ?? .max
      )
    let reportLines = reports.map { report in
      let offset = report.timestamp - initialTimestamp
      let bytes = report.bytes.map {
        String(format: "0x%02X", $0)
      }.joined(separator: ", ")
      return "report +\(offset): [\(bytes)]"
    }
    let valueLines = values.map { value in
      let offset = value.timestamp - initialTimestamp
      return
        "value +\(offset): usage \(value.usage), value \(value.integerValue)"
    }
    return (reportLines + valueLines).joined(separator: "\n")
  }
}

private enum Infinity3PhysicalRecorderError: Error {
  case couldNotOpen(IOReturn)
}

/// Protects callback-owned capture state with one lock and one queue.
private final class Infinity3PhysicalRecorder:
  @unchecked Sendable
{
  private let queue = DispatchQueue(
    label: "\(ApplicationIdentity.bundleIdentifier).physical_capture",
    qos: .userInteractive
  )
  private let lock = NSLock()
  private var reports: [Infinity3PhysicalCapture.Report] = []
  private var values: [Infinity3PhysicalCapture.Value] = []
  private var deviceMatched = false
  private var manager: IOHIDManager?

  var hasMatchedDevice: Bool {
    lock.withLock { deviceMatched }
  }

  var capture: Infinity3PhysicalCapture {
    lock.withLock {
      Infinity3PhysicalCapture(
        reports: reports,
        values: values
      )
    }
  }

  /// Opens only the confirmed Infinity 3 collection for exclusive capture.
  func start() throws {
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
    IOHIDManagerSetDeviceMatching(
      manager,
      matching as CFDictionary
    )

    let context = Unmanaged.passUnretained(self).toOpaque()
    IOHIDManagerRegisterDeviceMatchingCallback(
      manager,
      Self.deviceDidMatch,
      context
    )
    IOHIDManagerRegisterInputReportWithTimeStampCallback(
      manager,
      Self.reportReceived,
      context
    )
    IOHIDManagerRegisterInputValueCallback(
      manager,
      Self.valueReceived,
      context
    )
    let result = IOHIDManagerOpen(
      manager,
      IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
    )
    guard result == kIOReturnSuccess else {
      throw Infinity3PhysicalRecorderError.couldNotOpen(result)
    }

    self.manager = manager
    IOHIDManagerSetDispatchQueue(manager, queue)
    IOHIDManagerActivate(manager)
  }

  /// Closes exclusive input and waits for the dispatch queue to quiesce.
  func stop() {
    guard let manager else {
      return
    }
    IOHIDManagerClose(
      manager,
      IOOptionBits(kIOHIDOptionsTypeNone)
    )
    IOHIDManagerCancel(manager)
    queue.sync {}
    self.manager = nil
  }

  /// Records one raw report without retaining device identifiers.
  private func recordReport(
    timestamp: UInt64,
    report: UnsafeMutablePointer<UInt8>,
    length: CFIndex
  ) {
    guard length > 0 else {
      return
    }
    lock.withLock {
      reports.append(
        Infinity3PhysicalCapture.Report(
          timestamp: timestamp,
          bytes: Array(
            UnsafeBufferPointer(
              start: report,
              count: length
            )
          )
        )
      )
    }
  }

  /// Records one typed Button value without retaining device identifiers.
  private func recordValue(_ value: IOHIDValue) {
    let element = IOHIDValueGetElement(value)
    guard
      IOHIDElementGetUsagePage(element) == kHIDPage_Button
    else {
      return
    }
    lock.withLock {
      values.append(
        Infinity3PhysicalCapture.Value(
          timestamp: IOHIDValueGetTimeStamp(value),
          usage: IOHIDElementGetUsage(element),
          integerValue: IOHIDValueGetIntegerValue(value)
        )
      )
    }
  }

  /// Records only that the exact expected Device became available.
  private func recordDeviceMatch() {
    lock.withLock {
      deviceMatched = true
    }
  }

  /// Bridges exact Device matches into locked recorder state.
  private static let deviceDidMatch: IOHIDDeviceCallback = {
    context,
    result,
    _,
    _ in
    guard result == kIOReturnSuccess, let context else {
      return
    }
    Unmanaged<Infinity3PhysicalRecorder>
      .fromOpaque(context)
      .takeUnretainedValue()
      .recordDeviceMatch()
  }

  /// Bridges raw reports into identifier-free recorder state.
  private static let reportReceived: IOHIDReportWithTimeStampCallback = {
    context,
    result,
    _,
    type,
    _,
    report,
    reportLength,
    timestamp in
    guard
      result == kIOReturnSuccess,
      type == kIOHIDReportTypeInput,
      let context
    else {
      return
    }
    Unmanaged<Infinity3PhysicalRecorder>
      .fromOpaque(context)
      .takeUnretainedValue()
      .recordReport(
        timestamp: timestamp,
        report: report,
        length: reportLength
      )
  }

  /// Bridges typed Button values into identifier-free recorder state.
  private static let valueReceived: IOHIDValueCallback = {
    context,
    result,
    _,
    value in
    guard result == kIOReturnSuccess, let context else {
      return
    }
    Unmanaged<Infinity3PhysicalRecorder>
      .fromOpaque(context)
      .takeUnretainedValue()
      .recordValue(value)
  }
}
