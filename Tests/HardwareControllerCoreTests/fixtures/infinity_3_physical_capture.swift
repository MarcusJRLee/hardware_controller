import HardwareControllerCore

/// Stores identifier-free input captured from the purchased Infinity 3.
enum Infinity3PhysicalCaptureFixture {
  struct ExpectedTransition: Equatable, Sendable {
    let controlID: ControlID
    let phase: ControlPhase
  }

  struct Sample: Equatable, Sendable {
    let timestampOffsetNanoseconds: UInt64
    let report: [UInt8]
    let expectedTransitions: [ExpectedTransition]
  }

  /// Records enough context to reproduce and review the capture.
  static let manifest = (
    captureDate: "2026-07-30",
    macOSVersion: "26.5.2 (25F84)",
    captureTool:
      "Infinity3PhysicalCaptureTest.capturesPhysicalReportsAndTypedValues",
    machTimebase: "125/3 nanoseconds per tick",
    gestures:
      "left, center, right, every pair, then all three"
  )

  /// Preserves normalized timing, raw reports, and expected logical changes.
  static let samples: [Sample] = [
    Sample(
      timestampOffsetNanoseconds: 0,
      report: [0x01, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .left, phase: .pressed)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 4_639_983_041,
      report: [0x00, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .left, phase: .released)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 5_215_960_375,
      report: [0x02, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .center, phase: .pressed)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 10_407_990_041,
      report: [0x00, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .center, phase: .released)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 11_783_992_791,
      report: [0x04, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .right, phase: .pressed)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 16_319_991_583,
      report: [0x00, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .right, phase: .released)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 17_344_000_583,
      report: [0x02, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .center, phase: .pressed)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 17_367_971_416,
      report: [0x03, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .left, phase: .pressed)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 19_095_994_958,
      report: [0x02, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .left, phase: .released)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 19_151_989_833,
      report: [0x00, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .center, phase: .released)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 20_455_994_416,
      report: [0x02, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .center, phase: .pressed)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 20_471_983_500,
      report: [0x06, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .right, phase: .pressed)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 22_143_988_833,
      report: [0x02, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .right, phase: .released)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 22_175_966_833,
      report: [0x00, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .center, phase: .released)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 23_711_991_166,
      report: [0x01, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .left, phase: .pressed)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 23_719_945_625,
      report: [0x05, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .right, phase: .pressed)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 25_695_992_041,
      report: [0x04, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .left, phase: .released)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 25_751_979_333,
      report: [0x00, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .right, phase: .released)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 27_119_986_125,
      report: [0x04, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .right, phase: .pressed)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 27_135_959_875,
      report: [0x06, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .center, phase: .pressed)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 27_143_947_208,
      report: [0x07, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .left, phase: .pressed)
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 29_551_984_416,
      report: [0x04, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .left, phase: .released),
        ExpectedTransition(controlID: .center, phase: .released),
      ]
    ),
    Sample(
      timestampOffsetNanoseconds: 29_575_967_833,
      report: [0x00, 0x00],
      expectedTransitions: [
        ExpectedTransition(controlID: .right, phase: .released)
      ]
    ),
  ]
}
