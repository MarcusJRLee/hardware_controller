import Testing

@testable import HardwareControllerCore

struct Infinity3DriverTest {
  private let deviceID = DeviceID(rawValue: "infinity")

  @Test
  func matchesPublishedIdentity() {
    #expect(Infinity3Driver.vendorID == 0x05F3)
    #expect(Infinity3Driver.productID == 0x00FF)
    #expect(Infinity3Driver.usagePage == 0x0C)
    #expect(Infinity3Driver.usage == 0x03)
  }

  @Test
  func describesControlsWithoutDuplicatingDecoderOrder() {
    #expect(Infinity3Driver.descriptor.modelID == .vecInfinity3)
    #expect(
      Infinity3Driver.descriptor.controls.map(\.id)
        == [.left, .center, .right]
    )
    #expect(
      Infinity3Driver.descriptor.controls[1].visualWeight
        == .prominent
    )
    #expect(
      Infinity3Driver.controls
        == Infinity3Driver.descriptor.controls.map(\.id)
    )
    #expect(
      Infinity3Driver.buttonMappings.map(\.reportMask)
        == [0b001, 0b010, 0b100]
    )
    #expect(
      Infinity3Driver.buttonMappings.map(\.usage)
        == [1, 2, 3]
    )
  }

  /// Uses one confirmed mapping for live elements and raw reports.
  @Test
  func mapsButtonUsagesToLogicalControls() {
    #expect(
      Infinity3Driver.controlID(forButtonUsage: 1) == .left
    )
    #expect(
      Infinity3Driver.controlID(forButtonUsage: 2) == .center
    )
    #expect(
      Infinity3Driver.controlID(forButtonUsage: 3) == .right
    )
    #expect(
      Infinity3Driver.controlID(forButtonUsage: 4) == nil
    )
  }

  @Test
  func decodesCenterPressHoldAndRelease() throws {
    var decoder = Infinity3ReportDecoder()

    let press = try decoder.decode(
      [0b010, 0],
      deviceID: deviceID,
      timestampNanoseconds: 1
    )
    let hold = try decoder.decode(
      [0b010, 0],
      deviceID: deviceID,
      timestampNanoseconds: 2
    )
    let release = try decoder.decode(
      [0, 0],
      deviceID: deviceID,
      timestampNanoseconds: 3
    )

    #expect(press == [event(.center, .pressed, timestamp: 1)])
    #expect(hold.isEmpty)
    #expect(release == [event(.center, .released, timestamp: 3)])
  }

  @Test
  func decodesSimultaneousTransitionsInStableOrder() throws {
    var decoder = Infinity3ReportDecoder()
    let pressed = try decoder.decode(
      [0b101, 0],
      deviceID: deviceID,
      timestampNanoseconds: 1
    )
    let changed = try decoder.decode(
      [0b010, 0],
      deviceID: deviceID,
      timestampNanoseconds: 2
    )

    #expect(
      pressed == [
        event(.left, .pressed, timestamp: 1),
        event(.right, .pressed, timestamp: 1),
      ]
    )
    #expect(
      changed == [
        event(.left, .released, timestamp: 2),
        event(.center, .pressed, timestamp: 2),
        event(.right, .released, timestamp: 2),
      ]
    )
  }

  /// Replays the sanitized purchased-unit capture through the raw decoder.
  @Test
  func decodesSanitizedPhysicalCapture() throws {
    var decoder = Infinity3ReportDecoder()
    let actual = try Infinity3PhysicalCaptureFixture.samples
      .flatMap { sample in
        try decoder.decode(
          sample.report,
          deviceID: deviceID,
          timestampNanoseconds: sample.timestampOffsetNanoseconds
        )
      }
    let expected = Infinity3PhysicalCaptureFixture.samples
      .flatMap { sample in
        sample.expectedTransitions.map { transition in
          event(
            transition.controlID,
            transition.phase,
            timestamp: sample.timestampOffsetNanoseconds
          )
        }
      }

    #expect(actual == expected)
  }

  @Test
  func rejectsUnexpectedReportLength() {
    var decoder = Infinity3ReportDecoder()

    #expect(throws: Infinity3ReportError.invalidLength(actual: 1)) {
      try decoder.decode(
        [0],
        deviceID: deviceID,
        timestampNanoseconds: 1
      )
    }
  }

  private func event(
    _ controlID: ControlID,
    _ phase: ControlPhase,
    timestamp: UInt64
  ) -> ControlEvent {
    ControlEvent(
      deviceID: deviceID,
      controlID: controlID,
      phase: phase,
      timestampNanoseconds: timestamp
    )
  }
}
