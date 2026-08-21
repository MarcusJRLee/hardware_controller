import AVFoundation
import HardwareControllerAudioBoundary
import Testing

struct AudioEngineExceptionBoundaryTest {
  /// Converts a duplicate-tap exception into a recoverable error.
  @Test
  func duplicateTapInstallationThrowsAnError() throws {
    let engine = AVAudioEngine()
    let node = engine.inputNode

    try HCAudioEngineExceptionBoundary.installTap(
      on: node,
      bus: 0,
      bufferSize: 1_024,
      format: nil
    ) { _, _ in }
    defer {
      node.removeTap(onBus: 0)
    }

    #expect(throws: (any Error).self) {
      try HCAudioEngineExceptionBoundary.installTap(
        on: node,
        bus: 0,
        bufferSize: 1_024,
        format: nil
      ) { _, _ in }
    }
  }

  /// Keeps cleanup idempotent when no tap remains.
  @Test
  func missingTapRemovalIsSafe() {
    let engine = AVAudioEngine()

    do {
      try HCAudioEngineExceptionBoundary.removeTap(
        from: engine.inputNode,
        bus: 0
      )
    } catch {
      Issue.record("Unexpected cleanup error: \(error)")
    }
  }
}
