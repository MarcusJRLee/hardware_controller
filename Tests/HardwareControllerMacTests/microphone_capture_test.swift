import AVFoundation
import Foundation
import Testing

@testable import HardwareControllerMac

struct MicrophoneCaptureTest {
  /// Presents associated capture detail instead of an opaque enum code.
  @Test
  func captureFailurePreservesActionableDescription() {
    let error = MicrophoneCaptureError.couldNotMonitorInput(
      "CoreAudio detail."
    )

    #expect(error.localizedDescription == "CoreAudio detail.")
  }

  @Test
  func preparationPrimesEngineWithoutCapturing() async throws {
    let engine = FakeAudioEngine()
    let capture = AVAudioEngineMicrophoneCapture(engine: engine)

    try await capture.prepare()

    #expect(engine.prepareCount == 1)
    #expect(engine.installCount == 0)
    #expect(engine.startCount == 0)
  }

  @Test
  func startAndStopOwnOneAudioEngineTap() async throws {
    let engine = FakeAudioEngine()
    let capture = AVAudioEngineMicrophoneCapture(engine: engine)

    _ = try await capture.start()

    #expect(engine.installCount == 1)
    #expect(engine.startCount == 1)

    do {
      _ = try await capture.start()
      Issue.record("A second start should be rejected.")
    } catch {
      #expect(error as? MicrophoneCaptureError == .alreadyRunning)
    }

    await capture.stop()

    #expect(engine.stopCount == 1)
    #expect(engine.removeCount == 2)
  }

  /// Stops active capture before applying a new app-local microphone.
  @Test
  func selectionStopsCaptureBeforeChangingTheEngineRoute() async throws {
    let engine = FakeAudioEngine()
    let capture = AVAudioEngineMicrophoneCapture(engine: engine)
    _ = try await capture.start()

    await capture.selectInputDevice(uniqueID: "usb-microphone")

    #expect(engine.stopCount == 1)
    #expect(engine.selectedInputDeviceUID == "usb-microphone")
  }

  /// Ends active capture explicitly when its input configuration changes.
  @Test
  func inputConfigurationChangeFailsTheActiveStream() async throws {
    let engine = FakeAudioEngine()
    let capture = AVAudioEngineMicrophoneCapture(engine: engine)
    let stream = try await capture.start()

    engine.changeInputConfiguration()

    do {
      for try await _ in stream {}
      Issue.record("Expected the changed input to fail capture.")
    } catch {
      #expect(
        error as? MicrophoneCaptureError
          == .inputConfigurationChanged
      )
    }

    await capture.stop()

    _ = try await capture.start()
    #expect(engine.startCount == 2)
    await capture.stop()
  }

  @Test
  func failedEngineStartRemovesTheInstalledTap() async {
    let engine = FakeAudioEngine(startError: TestError.start)
    let capture = AVAudioEngineMicrophoneCapture(engine: engine)

    do {
      _ = try await capture.start()
      Issue.record("Expected audio start to fail.")
    } catch {
      guard
        case .couldNotStart = error as? MicrophoneCaptureError
      else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }

    #expect(engine.installCount == 1)
    #expect(engine.removeCount == 2)
    #expect(engine.stopCount == 0)
  }

  /// Proves callback-buffer reuse cannot mutate queued audio.
  @Test
  func yieldedAudioOwnsAnImmutableSampleCopy() async throws {
    let engine = FakeAudioEngine()
    let capture = AVAudioEngineMicrophoneCapture(engine: engine)
    let stream = try await capture.start()
    var iterator = stream.makeAsyncIterator()
    let source = try #require(
      AVAudioPCMBuffer(
        pcmFormat: engine.inputFormat,
        frameCapacity: 2
      )
    )
    source.frameLength = 2
    let sourceSamples = try #require(source.floatChannelData)
    sourceSamples[0][0] = 0.25
    sourceSamples[0][1] = 0.75

    engine.emit(source)
    sourceSamples[0][0] = 1
    sourceSamples[0][1] = 1

    let captured = try #require(try await iterator.next())
    let reconstructed = try captured.makePCMBuffer()
    let reconstructedSamples = try #require(
      reconstructed.floatChannelData
    )
    #expect(reconstructedSamples[0][0] == 0.25)
    #expect(reconstructedSamples[0][1] == 0.75)

    await capture.stop()
  }

  /// Preserves interleaved channel ordering across immutable storage.
  @Test
  func interleavedAudioRoundTripsExactly() throws {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
      )
    )
    let source = try #require(
      AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: 2
      )
    )
    source.frameLength = 2
    let samples = try #require(source.int16ChannelData)
    samples[0][0] = 10
    samples[0][1] = 20
    samples[0][2] = 30
    samples[0][3] = 40

    let captured = try CapturedAudioBuffer(copying: source)
    let reconstructed = try captured.makePCMBuffer()
    let copiedSamples = try #require(
      reconstructed.int16ChannelData
    )

    #expect(reconstructed.frameLength == 2)
    #expect(reconstructed.format == source.format)
    #expect(copiedSamples[0][0] == 10)
    #expect(copiedSamples[0][1] == 20)
    #expect(copiedSamples[0][2] == 30)
    #expect(copiedSamples[0][3] == 40)
  }

  /// Rejects empty callback buffers instead of crossing invalid state.
  @Test
  func emptyAudioIsRejected() throws {
    let format = try #require(
      AVAudioFormat(
        standardFormatWithSampleRate: 48_000,
        channels: 1
      )
    )
    let source = try #require(
      AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: 1
      )
    )

    #expect(throws: MicrophoneCaptureError.self) {
      _ = try CapturedAudioBuffer(copying: source)
    }
  }

  /// Converts a full queue into one explicit overflow failure.
  @Test
  func bufferOverflowTerminatesTheStream() async throws {
    let engine = FakeAudioEngine()
    let capture = AVAudioEngineMicrophoneCapture(engine: engine)
    let stream = try await capture.start()
    let source = try #require(
      AVAudioPCMBuffer(
        pcmFormat: engine.inputFormat,
        frameCapacity: 1
      )
    )
    source.frameLength = 1

    for _ in 0..<33 {
      engine.emit(source)
    }

    do {
      for try await _ in stream {}
      Issue.record("Expected bounded audio capture to overflow.")
    } catch {
      #expect(error as? MicrophoneCaptureError == .bufferOverflow)
    }

    await capture.stop()
  }

  /// Captures from an explicit real Device without changing the system default.
  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_RUN_MICROPHONE_INTEGRATION"
        ] == "1"
    )
  )
  func explicitRealMicrophonePreservesTheSystemDefault() async throws {
    #expect(MicrophonePermission.status == .authorized)
    let defaultRoute = try SystemAudioEnvironment().currentInputRoute()
    let devices = try SystemAudioInputDeviceDiscovery()
      .availableInputDevices()
    let selected = try #require(
      devices.first(where: { device in
        let route = try? SystemAudioEnvironment(
          preferredDeviceUID: device.uniqueID
        ).currentInputRoute()
        return route?.deviceID == defaultRoute.deviceID
      })
    )
    let capture = AVAudioEngineMicrophoneCapture(
      preferredInputDeviceUID: selected.uniqueID
    )

    try await capture.prepare()
    let stream = try await capture.start()
    let bufferIntervals: [Duration]
    do {
      bufferIntervals = try await captureIntervals(
        from: stream,
        sampleCount: 24
      )
    } catch {
      await capture.stop()
      throw error
    }
    await capture.stop()

    let steadyIntervals = bufferIntervals.dropFirst().sorted()
    let p50 = try #require(percentile(0.50, in: steadyIntervals))
    let p95 = try #require(percentile(0.95, in: steadyIntervals))
    let p99 = try #require(percentile(0.99, in: steadyIntervals))
    let maximum = try #require(steadyIntervals.last)
    print(
      "Explicit microphone buffer interval: p50 \(p50), p95 \(p95), p99 \(p99), max \(maximum), samples \(steadyIntervals.count)"
    )
    #expect(maximum < .milliseconds(250))
    #expect(
      try SystemAudioEnvironment().currentInputRoute().deviceID
        == defaultRoute.deviceID
    )
  }

  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_RUN_MICROPHONE_INTEGRATION"
        ] == "1"
    )
  )
  func capturesARealAuthorizedMicrophoneBuffer() async throws {
    #expect(MicrophonePermission.status == .authorized)
    let capture = AVAudioEngineMicrophoneCapture()
    let clock = ContinuousClock()
    let preparationStart = clock.now
    try await capture.prepare()
    let preparation =
      preparationStart.duration(to: clock.now)
    var startupSamples: [Duration] = []

    for _ in 0..<5 {
      let start = clock.now
      let stream = try await capture.start()
      startupSamples.append(start.duration(to: clock.now))
      let firstBuffer = Task<
        CapturedAudioBuffer?,
        any Error
      > {
        for try await audio in stream {
          return audio
        }
        return nil
      }

      try await Task.sleep(for: .milliseconds(300))
      await capture.stop()
      let audio = try await firstBuffer.value
      #expect(audio != nil)
      #expect(
        try audio?.makePCMBuffer().frameLength ?? 0 > 0
      )
    }

    let sorted = startupSamples.sorted()
    let p50 = sorted[2]
    let p95 = sorted[4]
    let p99 = sorted[4]
    let maximum = try #require(sorted.last)
    print("One-time microphone preparation: \(preparation)")
    print(
      "Microphone startup: p50 \(p50), p95 \(p95), p99 \(p99), max \(maximum), samples \(sorted.count)"
    )
    // Preparation is one-time readiness work, not part of activation latency.
    #expect(maximum < .milliseconds(250))
  }

  /// Captures sustained nonempty audio or fails within a bounded interval.
  private func captureIntervals(
    from stream: AsyncThrowingStream<CapturedAudioBuffer, any Error>,
    sampleCount: Int
  ) async throws -> [Duration] {
    try await withThrowingTaskGroup(of: [Duration].self) { group in
      group.addTask {
        let clock = ContinuousClock()
        var previous = clock.now
        var intervals: [Duration] = []
        for try await audio in stream {
          let buffer = try audio.makePCMBuffer()
          guard buffer.frameLength > 0 else {
            throw TestError.streamEnded
          }
          let now = clock.now
          intervals.append(previous.duration(to: now))
          previous = now
          if intervals.count == sampleCount {
            return intervals
          }
        }
        throw TestError.streamEnded
      }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw TestError.timedOut
      }
      guard let result = try await group.next() else {
        throw TestError.streamEnded
      }
      group.cancelAll()
      return result
    }
  }

  /// Returns one nearest-rank duration percentile from sorted samples.
  private func percentile(
    _ percentile: Double,
    in sortedSamples: some RandomAccessCollection<Duration>
  ) -> Duration? {
    guard !sortedSamples.isEmpty else {
      return nil
    }
    let boundedPercentile = min(max(percentile, 0), 1)
    let offset = Int(
      (Double(sortedSamples.count - 1) * boundedPercentile).rounded(.up)
    )
    return sortedSamples[
      sortedSamples.index(sortedSamples.startIndex, offsetBy: offset)
    ]
  }
}

private enum TestError: Error {
  case start
  case streamEnded
  case timedOut
}

private final class FakeAudioEngine:
  AudioEngineControlling,
  @unchecked Sendable
{
  let inputFormat = AVAudioFormat(
    standardFormatWithSampleRate: 48_000,
    channels: 1
  )!

  private let lock = NSLock()
  private let startError: (any Error)?
  private var installs = 0
  private var removes = 0
  private var starts = 0
  private var stops = 0
  private var preparations = 0
  private var tapHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
  private var configurationChangeHandler: (@Sendable () -> Void)?
  private var selectedDeviceUID: String?

  init(startError: (any Error)? = nil) {
    self.startError = startError
  }

  var installCount: Int {
    lock.withLock { installs }
  }

  var removeCount: Int {
    lock.withLock { removes }
  }

  var startCount: Int {
    lock.withLock { starts }
  }

  var stopCount: Int {
    lock.withLock { stops }
  }

  var prepareCount: Int {
    lock.withLock { preparations }
  }

  var selectedInputDeviceUID: String? {
    lock.withLock { selectedDeviceUID }
  }

  /// Records one app-local selection.
  func selectInputDevice(uniqueID: String?) {
    lock.withLock {
      selectedDeviceUID = uniqueID
    }
  }

  func prepare() throws {
    lock.withLock {
      preparations += 1
    }
  }

  /// Installs one fake tap and starts or fails atomically.
  func startCapture(
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
    onConfigurationChange:
      @escaping @Sendable () -> Void
  ) throws {
    try lock.withLock {
      removes += 1
      installs += 1
      starts += 1
      tapHandler = onBuffer
      configurationChangeHandler = onConfigurationChange
      if let startError {
        removes += 1
        tapHandler = nil
        configurationChangeHandler = nil
        throw startError
      }
    }
  }

  func stop() {
    lock.withLock {
      stops += 1
      removes += 1
      tapHandler = nil
      configurationChangeHandler = nil
    }
  }

  /// Delivers one synthetic engine callback outside the lock.
  func emit(_ buffer: AVAudioPCMBuffer) {
    let handler = lock.withLock { tapHandler }
    handler?(buffer)
  }

  /// Publishes one active input-configuration change.
  func changeInputConfiguration() {
    let handler = lock.withLock {
      let handler = configurationChangeHandler
      configurationChangeHandler = nil
      return handler
    }
    handler?()
  }
}
