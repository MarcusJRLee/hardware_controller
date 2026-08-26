import Carbon
import HardwareControllerCore

/// Describes one exact global shortcut that macOS could not reserve.
public struct KeyboardFallbackRegistrationFailure: Equatable, Sendable {
  public let registration: KeyboardFallbackRegistration
  public let systemCode: Int32

  public init(
    registration: KeyboardFallbackRegistration,
    systemCode: Int32
  ) {
    self.registration = registration
    self.systemCode = systemCode
  }

  /// Gives the user a direct recovery path without interpreting system codes.
  public var recoveryMessage: String {
    "This keyboard fallback is unavailable. Record a different shortcut; another app or macOS may already use it."
  }
}

/// Describes the Voice shortcut when macOS could not reserve it.
public struct VoiceShortcutRegistrationFailure: Equatable, Sendable {
  public let shortcut: KeyboardShortcut
  public let systemCode: Int32

  public init(shortcut: KeyboardShortcut, systemCode: Int32) {
    self.shortcut = shortcut
    self.systemCode = systemCode
  }

  /// Gives the user a direct recovery path without interpreting system codes.
  public var recoveryMessage: String {
    "This Voice capture shortcut is unavailable. Record a different shortcut; another app or macOS may already use it."
  }
}

/// Reports all exact-shortcut registration outcomes in one transaction.
public struct KeyboardInputRegistrationResult: Equatable, Sendable {
  public let fallbackFailures: [KeyboardFallbackRegistrationFailure]
  public let voiceFailure: VoiceShortcutRegistrationFailure?

  public init(
    fallbackFailures: [KeyboardFallbackRegistrationFailure],
    voiceFailure: VoiceShortcutRegistrationFailure?
  ) {
    self.fallbackFailures = fallbackFailures
    self.voiceFailure = voiceFailure
  }
}

/// Abstracts exact Carbon hot-key registration for deterministic lifecycle tests.
@MainActor
protocol GlobalHotKeySystem: AnyObject {
  var onEvent: ((UInt32, ControlPhase) -> Void)? { get set }

  /// Reserves one exact chord and returns the macOS status code.
  func register(
    _ shortcut: KeyboardShortcut,
    id: UInt32
  ) -> Int32

  /// Releases one prior registration and returns the macOS status code.
  func unregister(id: UInt32) -> Int32
}

/// Converts exact global hot-key callbacks into Control transitions.
@MainActor
public final class KeyboardFallbackInputSource {
  public typealias EventHandler =
    @Sendable (
      KeyboardFallbackRegistration,
      ControlPhase,
      UInt64
    ) -> Void
  public typealias VoiceEventHandler =
    @Sendable (ControlPhase, UInt64) -> Void

  private enum Registration {
    case fallback(KeyboardFallbackRegistration)
    case voice(KeyboardShortcut)
  }

  private let system: any GlobalHotKeySystem
  private let onEvent: EventHandler
  private let onVoiceEvent: VoiceEventHandler
  private var registrationsByID: [UInt32: Registration] = [:]
  private var activeIDs: Set<UInt32> = []
  private var nextID: UInt32 = 1

  /// Installs a narrow exact-hot-key source without reading global key events.
  init(
    system: any GlobalHotKeySystem,
    onEvent: @escaping EventHandler,
    onVoiceEvent: @escaping VoiceEventHandler = { _, _ in }
  ) {
    self.system = system
    self.onEvent = onEvent
    self.onVoiceEvent = onVoiceEvent
    system.onEvent = { [weak self] id, phase in
      self?.handle(id: id, phase: phase)
    }
  }

  /// Creates the live exact-hot-key source on the main event target.
  public convenience init(
    onEvent: @escaping EventHandler,
    onVoiceEvent: @escaping VoiceEventHandler = { _, _ in }
  ) {
    self.init(
      system: CarbonGlobalHotKeySystem(),
      onEvent: onEvent,
      onVoiceEvent: onVoiceEvent
    )
  }

  /// Atomically replaces all active-Profile shortcut registrations.
  @discardableResult
  public func replace(
    with registrations: [KeyboardFallbackRegistration]
  ) -> [KeyboardFallbackRegistrationFailure] {
    replace(
      fallbacks: registrations,
      voiceShortcut: nil
    ).fallbackFailures
  }

  /// Atomically replaces Binding fallbacks and the independent Voice chord.
  @discardableResult
  public func replace(
    fallbacks: [KeyboardFallbackRegistration],
    voiceShortcut: KeyboardShortcut?
  ) -> KeyboardInputRegistrationResult {
    stop()

    var failures: [KeyboardFallbackRegistrationFailure] = []
    for registration in fallbacks {
      let id = nextID
      advanceID()
      let status = system.register(registration.shortcut, id: id)
      if status == noErr {
        registrationsByID[id] = .fallback(registration)
      } else {
        failures.append(
          KeyboardFallbackRegistrationFailure(
            registration: registration,
            systemCode: status
          )
        )
      }
    }

    var voiceFailure: VoiceShortcutRegistrationFailure?
    if let voiceShortcut {
      let id = nextID
      advanceID()
      let status = system.register(voiceShortcut, id: id)
      if status == noErr {
        registrationsByID[id] = .voice(voiceShortcut)
      } else {
        voiceFailure = VoiceShortcutRegistrationFailure(
          shortcut: voiceShortcut,
          systemCode: status
        )
      }
    }
    return KeyboardInputRegistrationResult(
      fallbackFailures: failures,
      voiceFailure: voiceFailure
    )
  }

  /// Releases active inputs before unregistering every exact shortcut.
  public func stop() {
    let timestamp = MonotonicClock.nowNanoseconds()
    for id in activeIDs.sorted() {
      if let registration = registrationsByID[id] {
        deliver(registration, phase: .released, timestamp: timestamp)
      }
    }
    activeIDs.removeAll()

    for id in registrationsByID.keys.sorted() {
      _ = system.unregister(id: id)
    }
    registrationsByID.removeAll()
  }

  /// Suppresses repeated transitions before they reach the Action hot path.
  private func handle(id: UInt32, phase: ControlPhase) {
    guard let registration = registrationsByID[id] else {
      return
    }
    switch phase {
    case .pressed:
      guard activeIDs.insert(id).inserted else {
        return
      }
    case .released:
      guard activeIDs.remove(id) != nil else {
        return
      }
    }
    deliver(
      registration,
      phase: phase,
      timestamp: MonotonicClock.nowNanoseconds()
    )
  }

  private func deliver(
    _ registration: Registration,
    phase: ControlPhase,
    timestamp: UInt64
  ) {
    switch registration {
    case .fallback(let fallback):
      onEvent(fallback, phase, timestamp)
    case .voice:
      onVoiceEvent(phase, timestamp)
    }
  }

  private func advanceID() {
    nextID = nextID == .max ? 1 : nextID + 1
  }
}

/// Owns Carbon registration handles on the application event target.
@MainActor
private final class CarbonGlobalHotKeySystem: GlobalHotKeySystem {
  /// Allows opaque Carbon ownership to cross the nonisolated deinitializer.
  private struct SendableEventHandlerRef: @unchecked Sendable {
    let value: EventHandlerRef
  }

  /// Allows opaque Carbon ownership to cross the nonisolated deinitializer.
  private struct SendableHotKeyRef: @unchecked Sendable {
    let value: EventHotKeyRef
  }

  var onEvent: ((UInt32, ControlPhase) -> Void)?

  private var eventHandler: SendableEventHandlerRef?
  private var hotKeyReferences: [UInt32: SendableHotKeyRef] = [:]
  private var handlerInstallStatus = OSStatus(eventNotHandledErr)

  /// Installs callbacks only for registered hot-key press and release events.
  init() {
    var eventTypes = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
      ),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyReleased)
      ),
    ]
    let context = Unmanaged.passUnretained(self).toOpaque()
    var installedHandler: EventHandlerRef?
    handlerInstallStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      Self.eventCallback,
      eventTypes.count,
      &eventTypes,
      context,
      &installedHandler
    )
    eventHandler = installedHandler.map(SendableEventHandlerRef.init)
  }

  /// Removes the callback before its unretained context can be deallocated.
  deinit {
    for reference in hotKeyReferences.values {
      UnregisterEventHotKey(reference.value)
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler.value)
    }
  }

  /// Reserves one exact chord exclusively against the application target.
  func register(
    _ shortcut: KeyboardShortcut,
    id: UInt32
  ) -> Int32 {
    guard handlerInstallStatus == noErr else {
      return handlerInstallStatus
    }
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(shortcut.keyCode),
      shortcut.carbonModifiers,
      EventHotKeyID(signature: Self.signature, id: id),
      GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive),
      &reference
    )
    if status == noErr, let reference {
      hotKeyReferences[id] = SendableHotKeyRef(value: reference)
    }
    return status
  }

  /// Releases one exact chord if it was successfully registered.
  func unregister(id: UInt32) -> Int32 {
    guard let reference = hotKeyReferences.removeValue(forKey: id) else {
      return noErr
    }
    return UnregisterEventHotKey(reference.value)
  }

  /// Routes Carbon callbacks through the retained source instance.
  private static let eventCallback: EventHandlerUPP = {
    _, event, context in
    guard let event, let context else {
      return OSStatus(eventNotHandledErr)
    }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == signature else {
      return status == noErr ? OSStatus(eventNotHandledErr) : status
    }

    let phase: ControlPhase
    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed):
      phase = .pressed
    case UInt32(kEventHotKeyReleased):
      phase = .released
    default:
      return OSStatus(eventNotHandledErr)
    }
    let system = Unmanaged<CarbonGlobalHotKeySystem>
      .fromOpaque(context)
      .takeUnretainedValue()
    system.onEvent?(hotKeyID.id, phase)
    return noErr
  }

  /// Uses a stable four-byte signature scoped to this process.
  private static let signature: OSType = 0x4843_4B46
}

extension KeyboardShortcut {
  /// Converts typed modifiers into Carbon's registration mask.
  fileprivate var carbonModifiers: UInt32 {
    modifiers.reduce(into: UInt32(0)) { result, modifier in
      switch modifier {
      case .command:
        result |= UInt32(cmdKey)
      case .option:
        result |= UInt32(optionKey)
      case .shift:
        result |= UInt32(shiftKey)
      case .control:
        result |= UInt32(controlKey)
      case .function:
        result |= UInt32(kEventKeyModifierFnMask)
      }
    }
  }
}
