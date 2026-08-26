import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

@MainActor
struct KeyboardFallbackInputSourceTest {
  /// Reserves exact chords and suppresses duplicate press or release callbacks.
  @Test
  func registrationDeliversOneTransitionPerStateChange() {
    let system = FakeGlobalHotKeySystem()
    let recorder = KeyboardFallbackEventRecorder()
    let source = KeyboardFallbackInputSource(
      system: system,
      onEvent: recorder.append
    )
    let registration = makeRegistration()

    let failures = source.replace(with: [registration])
    system.send(id: 1, phase: .pressed)
    system.send(id: 1, phase: .pressed)
    system.send(id: 1, phase: .released)
    system.send(id: 1, phase: .released)

    #expect(failures.isEmpty)
    #expect(system.registeredIDs == [1])
    #expect(recorder.phases == [.pressed, .released])
  }

  /// Releases active ownership before replacing or stopping registrations.
  @Test
  func replacementReleasesActiveInputBeforeUnregistering() {
    let system = FakeGlobalHotKeySystem()
    let recorder = KeyboardFallbackEventRecorder()
    let source = KeyboardFallbackInputSource(
      system: system,
      onEvent: recorder.append
    )
    _ = source.replace(with: [makeRegistration()])
    system.send(id: 1, phase: .pressed)

    _ = source.replace(with: [])

    #expect(recorder.phases == [.pressed, .released])
    #expect(system.unregisteredIDs == [1])
  }

  /// Returns typed failures while leaving unavailable chords unregistered.
  @Test
  func registrationFailureIsReported() throws {
    let system = FakeGlobalHotKeySystem(registerStatus: -9876)
    let source = KeyboardFallbackInputSource(
      system: system,
      onEvent: { _, _, _ in }
    )
    let registration = makeRegistration()

    let failure = try #require(
      source.replace(with: [registration]).first
    )
    system.send(id: 1, phase: .pressed)

    #expect(failure.registration == registration)
    #expect(failure.systemCode == -9876)
    #expect(system.unregisteredIDs.isEmpty)
  }

  @Test
  func voiceShortcutDeliversIndependentTransitions() {
    let system = FakeGlobalHotKeySystem()
    let recorder = VoiceShortcutEventRecorder()
    let source = KeyboardFallbackInputSource(
      system: system,
      onEvent: { _, _, _ in },
      onVoiceEvent: recorder.append
    )

    let result = source.replace(
      fallbacks: [],
      voiceShortcut: .suggestedControlActivation
    )
    system.send(id: 1, phase: .pressed)
    system.send(id: 1, phase: .pressed)
    system.send(id: 1, phase: .released)

    #expect(
      result
        == KeyboardInputRegistrationResult(
          fallbackFailures: [],
          voiceFailure: nil
        ))
    #expect(recorder.phases == [.pressed, .released])
  }

  @Test
  func voiceRegistrationFailureIsTyped() throws {
    let system = FakeGlobalHotKeySystem(registerStatus: -9876)
    let source = KeyboardFallbackInputSource(
      system: system,
      onEvent: { _, _, _ in }
    )

    let failure = try #require(
      source.replace(
        fallbacks: [],
        voiceShortcut: .suggestedControlActivation
      ).voiceFailure
    )

    #expect(failure.shortcut == .suggestedControlActivation)
    #expect(failure.systemCode == -9876)
    #expect(failure.recoveryMessage.contains("different shortcut"))
  }

  /// Creates one deterministic active-Profile fallback registration.
  private func makeRegistration() -> KeyboardFallbackRegistration {
    KeyboardFallbackRegistration(
      targetID: BindingTargetID(
        configurationID: UUID(),
        controlID: .center
      ),
      sourceDeviceID: DeviceID(rawValue: "keyboard-fallback-test"),
      shortcut: .suggestedControlActivation
    )
  }
}

private final class VoiceShortcutEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var phaseStorage: [ControlPhase] = []

  var phases: [ControlPhase] {
    lock.withLock { phaseStorage }
  }

  func append(_ phase: ControlPhase, _ timestampNanoseconds: UInt64) {
    lock.withLock {
      phaseStorage.append(phase)
    }
  }
}

/// Records callback phases behind a lock because the production closure is Sendable.
private final class KeyboardFallbackEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var phaseStorage: [ControlPhase] = []

  var phases: [ControlPhase] {
    lock.withLock { phaseStorage }
  }

  /// Records one delivered exact-hot-key transition.
  func append(
    _ registration: KeyboardFallbackRegistration,
    _ phase: ControlPhase,
    _ timestampNanoseconds: UInt64
  ) {
    lock.withLock {
      phaseStorage.append(phase)
    }
  }
}

/// Simulates Carbon registration and exact hot-key callbacks on the main actor.
@MainActor
private final class FakeGlobalHotKeySystem: GlobalHotKeySystem {
  var onEvent: ((UInt32, ControlPhase) -> Void)?
  private(set) var registeredIDs: [UInt32] = []
  private(set) var unregisteredIDs: [UInt32] = []
  private let registerStatus: Int32

  /// Creates one deterministic registration result.
  init(registerStatus: Int32 = 0) {
    self.registerStatus = registerStatus
  }

  /// Records one requested exact chord reservation.
  func register(
    _ shortcut: KeyboardShortcut,
    id: UInt32
  ) -> Int32 {
    registeredIDs.append(id)
    return registerStatus
  }

  /// Records one successful-registration cleanup.
  func unregister(id: UInt32) -> Int32 {
    unregisteredIDs.append(id)
    return 0
  }

  /// Emits one deterministic system callback.
  func send(id: UInt32, phase: ControlPhase) {
    onEvent?(id, phase)
  }
}
