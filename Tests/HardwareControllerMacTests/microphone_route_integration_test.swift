import AVFoundation
@preconcurrency import CoreAudio
import Foundation
import Testing

@testable import HardwareControllerMac

struct MicrophoneRouteIntegrationTest {
  /// Verifies idle and active capture across a real input reconfiguration.
  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_RUN_MICROPHONE_ROUTE_INTEGRATION"
        ] == "1"
    )
  )
  func changesTheRealDefaultInputWithoutCrashing() async throws {
    #expect(MicrophonePermission.status == .authorized)
    let original = try SystemInputTestSupport.defaultInput()
    let alternates =
      try SystemInputTestSupport.alternateConfigurations(
        from: original
      )
    _ = try #require(alternates.first)

    for alternate in alternates {
      try await verifyRouteChange(
        from: original,
        to: alternate
      )
    }
  }

  /// Verifies prepared, active, and recovered capture for one real transition.
  private func verifyRouteChange(
    from original: SystemInputTestDevice,
    to alternate: SystemInputTestDevice
  ) async throws {
    let capture = AVAudioEngineMicrophoneCapture()
    print(
      "Testing microphone route: \(original.description) -> \(alternate.description)"
    )
    defer {
      do {
        try SystemInputTestSupport.apply(original)
      } catch {
        Issue.record(
          "Could not restore the default microphone: \(error)"
        )
      }
    }

    try await capture.prepare()
    try SystemInputTestSupport.apply(alternate)
    try await SystemInputTestSupport.waitForConfiguration(
      alternate
    )
    do {
      let stream = try await capture.start()
      _ = try await firstBuffer(
        from: stream,
        stage: "prepared-route start"
      )
      await capture.stop()
    } catch {
      await capture.stop()
      throw error
    }

    let activeFailure: MicrophoneCaptureError
    do {
      let activeStream = try await capture.start()
      try SystemInputTestSupport.apply(original)
      try await SystemInputTestSupport.waitForConfiguration(
        original
      )
      activeFailure = try await terminalCaptureError(
        from: activeStream
      )
      await capture.stop()
    } catch {
      await capture.stop()
      throw error
    }

    #expect(
      activeFailure == .inputConfigurationChanged
    )
    do {
      let recoveredStream = try await capture.start()
      _ = try await firstBuffer(
        from: recoveredStream,
        stage: "recovered start"
      )
      await capture.stop()
    } catch {
      await capture.stop()
      throw error
    }
    print(
      "Microphone route: \(original.description) -> \(alternate.description) -> \(original.description)"
    )
  }

  /// Returns the first captured buffer within a bounded interval.
  private func firstBuffer(
    from stream:
      AsyncThrowingStream<CapturedAudioBuffer, any Error>,
    stage: String
  ) async throws -> CapturedAudioBuffer {
    try await withThrowingTaskGroup(
      of: CapturedAudioBuffer.self
    ) { group in
      group.addTask {
        for try await buffer in stream {
          return buffer
        }
        throw SystemInputTestError.streamEnded
      }
      group.addTask {
        try await Task.sleep(for: .seconds(2))
        throw SystemInputTestError.timeout(stage)
      }
      let result = try await #require(group.next())
      group.cancelAll()
      return result
    }
  }

  /// Returns the terminal typed capture failure within a bounded interval.
  private func terminalCaptureError(
    from stream:
      AsyncThrowingStream<CapturedAudioBuffer, any Error>
  ) async throws -> MicrophoneCaptureError {
    try await withThrowingTaskGroup(
      of: MicrophoneCaptureError.self
    ) { group in
      group.addTask {
        do {
          for try await _ in stream {}
          throw SystemInputTestError.streamEnded
        } catch let error as MicrophoneCaptureError {
          return error
        }
      }
      group.addTask {
        try await Task.sleep(for: .seconds(2))
        throw SystemInputTestError.timeout(
          "active-route invalidation"
        )
      }
      let result = try await #require(group.next())
      group.cancelAll()
      return result
    }
  }
}

private struct SystemInputTestDevice: Equatable, Sendable {
  let id: AudioDeviceID
  let name: String
  let sampleRate: Float64
  let channelCount: UInt32
  let transportType: UInt32

  var description: String {
    "\(name) [\(Int(sampleRate)) Hz, \(channelCount) ch]"
  }
}

private enum SystemInputTestError: Error {
  case coreAudio(OSStatus, String)
  case missingDeviceName
  case noDefaultInput
  case streamEnded
  case timeout(String)
}

private enum SystemInputTestSupport {
  /// Reads the current default input and its hardware shape.
  static func defaultInput() throws -> SystemInputTestDevice {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var id = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &id
    )
    try requireSuccess(status, operation: "read default input")
    guard id != kAudioObjectUnknown else {
      throw SystemInputTestError.noDefaultInput
    }
    return try inputDevice(id: id)
  }

  /// Chooses distinct-Device and same-Device rate transitions when available.
  static func alternateConfigurations(
    from original: SystemInputTestDevice
  ) throws -> [SystemInputTestDevice] {
    var alternates: [SystemInputTestDevice] = []
    let candidates = try inputDevices().filter {
      $0.id != original.id
        && $0.transportType
          != kAudioDeviceTransportTypeVirtual
        && !$0.name.localizedCaseInsensitiveContains("iPhone")
    }
    if let headset = candidates.first(where: {
      $0.name.localizedCaseInsensitiveContains("Scarlet")
    }) {
      alternates.append(headset)
    } else if let differentRate = candidates.first(where: {
      $0.sampleRate != original.sampleRate
    }) {
      alternates.append(differentRate)
    } else if let candidate = candidates.first {
      alternates.append(candidate)
    }
    if let rate = try alternateSampleRate(for: original) {
      alternates.append(
        SystemInputTestDevice(
          id: original.id,
          name: original.name,
          sampleRate: rate,
          channelCount: original.channelCount,
          transportType: original.transportType
        )
      )
    }
    return alternates
  }

  /// Applies either a rate change or a default-input replacement.
  static func apply(
    _ device: SystemInputTestDevice
  ) throws {
    let current = try defaultInput()
    if current.id == device.id {
      try setSampleRate(device)
      return
    }
    try setDefaultInput(device)
  }

  /// Changes the system default input for the duration of this test.
  private static func setDefaultInput(
    _ device: SystemInputTestDevice
  ) throws {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var id = device.id
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      size,
      &id
    )
    try requireSuccess(status, operation: "change default input")
  }

  /// Changes one Device's nominal sample rate.
  private static func setSampleRate(
    _ device: SystemInputTestDevice
  ) throws {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var rate = device.sampleRate
    let size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectSetPropertyData(
      device.id,
      &address,
      0,
      nil,
      size,
      &rate
    )
    try requireSuccess(
      status,
      operation: "change input sample rate"
    )
  }

  /// Waits for CoreAudio to publish the requested input shape.
  static func waitForConfiguration(
    _ expected: SystemInputTestDevice
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if try defaultInput() == expected {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw SystemInputTestError.timeout(
      "default-route publication"
    )
  }

  /// Selects a common supported nominal rate different from the current rate.
  private static func alternateSampleRate(
    for device: SystemInputTestDevice
  ) throws -> Float64? {
    var address = AudioObjectPropertyAddress(
      mSelector:
        kAudioDevicePropertyAvailableNominalSampleRates,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32.zero
    var status = AudioObjectGetPropertyDataSize(
      device.id,
      &address,
      0,
      nil,
      &size
    )
    try requireSuccess(
      status,
      operation: "size available input rates"
    )
    let count =
      Int(size) / MemoryLayout<AudioValueRange>.size
    var ranges = [AudioValueRange](
      repeating: AudioValueRange(),
      count: count
    )
    status = AudioObjectGetPropertyData(
      device.id,
      &address,
      0,
      nil,
      &size,
      &ranges
    )
    try requireSuccess(
      status,
      operation: "read available input rates"
    )
    let commonRates: [Float64] = [
      44_100,
      48_000,
      88_200,
      96_000,
    ]
    return commonRates.first { candidate in
      candidate != device.sampleRate
        && ranges.contains {
          $0.mMinimum <= candidate
            && $0.mMaximum >= candidate
        }
    }
  }

  /// Enumerates every connected Device with input channels.
  private static func inputDevices() throws
    -> [SystemInputTestDevice]
  {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32.zero
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size
    )
    try requireSuccess(status, operation: "size audio devices")
    let count =
      Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](
      repeating: kAudioObjectUnknown,
      count: count
    )
    status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &ids
    )
    try requireSuccess(status, operation: "read audio devices")
    return try ids.compactMap { id in
      let device = try inputDevice(id: id)
      return device.channelCount > 0 ? device : nil
    }
  }

  /// Reads the name, rate, channels, and transport for one Device.
  private static func inputDevice(
    id: AudioDeviceID
  ) throws -> SystemInputTestDevice {
    try SystemInputTestDevice(
      id: id,
      name: deviceName(id: id),
      sampleRate: sampleRate(id: id),
      channelCount: channelCount(id: id),
      transportType: transportType(id: id)
    )
  }

  /// Reads one Device's physical or virtual transport type.
  private static func transportType(
    id: AudioDeviceID
  ) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var transportType = UInt32.zero
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
      id,
      &address,
      0,
      nil,
      &size,
      &transportType
    )
    try requireSuccess(
      status,
      operation: "read device transport"
    )
    return transportType
  }

  /// Reads one Device's display name.
  private static func deviceName(
    id: AudioDeviceID
  ) throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(
      MemoryLayout<Unmanaged<CFString>?>.size
    )
    let status = AudioObjectGetPropertyData(
      id,
      &address,
      0,
      nil,
      &size,
      &name
    )
    try requireSuccess(status, operation: "read device name")
    guard let name else {
      throw SystemInputTestError.missingDeviceName
    }
    return name.takeUnretainedValue() as String
  }

  /// Reads one Device's current nominal rate.
  private static func sampleRate(
    id: AudioDeviceID
  ) throws -> Float64 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var rate = Float64.zero
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(
      id,
      &address,
      0,
      nil,
      &size,
      &rate
    )
    try requireSuccess(status, operation: "read device rate")
    return rate
  }

  /// Counts one Device's current input channels.
  private static func channelCount(
    id: AudioDeviceID
  ) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32.zero
    var status = AudioObjectGetPropertyDataSize(
      id,
      &address,
      0,
      nil,
      &size
    )
    try requireSuccess(status, operation: "size input channels")
    guard size >= MemoryLayout<AudioBufferList>.size else {
      return 0
    }
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer {
      storage.deallocate()
    }
    let list = storage.bindMemory(
      to: AudioBufferList.self,
      capacity: 1
    )
    status = AudioObjectGetPropertyData(
      id,
      &address,
      0,
      nil,
      &size,
      list
    )
    try requireSuccess(status, operation: "read input channels")
    return UnsafeMutableAudioBufferListPointer(list)
      .reduce(UInt32.zero) {
        $0 + $1.mNumberChannels
      }
  }

  /// Converts CoreAudio status codes into test failures.
  private static func requireSuccess(
    _ status: OSStatus,
    operation: String
  ) throws {
    guard status == noErr else {
      throw SystemInputTestError.coreAudio(
        status,
        operation
      )
    }
  }
}
