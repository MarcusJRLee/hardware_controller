import CoreGraphics
import Foundation
import HardwareControllerCore

public protocol ActionExecuting: Sendable {
  func execute(_ invocation: ActionInvocation) -> Bool
  func shutdown()
}

extension ActionExecuting {
  public func shutdown() {}
}

public struct KeyboardEventDescriptor: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case key
    case modifier
  }

  public enum Phase: Equatable, Sendable {
    case down
    case up
  }

  public let kind: Kind
  public let keyCode: UInt16
  public let phase: Phase
  public let modifiers: Set<KeyModifier>

  public init(
    kind: Kind = .key,
    keyCode: UInt16,
    phase: Phase,
    modifiers: Set<KeyModifier>
  ) {
    self.kind = kind
    self.keyCode = keyCode
    self.phase = phase
    self.modifiers = modifiers
  }
}

public enum KeyboardEventPlan {
  public static func events(
    for shortcut: KeyboardShortcut
  ) -> [KeyboardEventDescriptor] {
    let modifiers = KeyModifier.postingOrder.filter {
      shortcut.modifiers.contains($0)
    }
    var activeModifiers: Set<KeyModifier> = []
    var events: [KeyboardEventDescriptor] = []

    for modifier in modifiers {
      activeModifiers.insert(modifier)
      events.append(
        KeyboardEventDescriptor(
          kind: .modifier,
          keyCode: modifier.virtualKeyCode,
          phase: .down,
          modifiers: activeModifiers
        )
      )
    }

    events.append(
      KeyboardEventDescriptor(
        keyCode: shortcut.keyCode,
        phase: .down,
        modifiers: activeModifiers
      )
    )
    events.append(
      KeyboardEventDescriptor(
        keyCode: shortcut.keyCode,
        phase: .up,
        modifiers: activeModifiers
      )
    )

    for modifier in modifiers.reversed() {
      activeModifiers.remove(modifier)
      events.append(
        KeyboardEventDescriptor(
          kind: .modifier,
          keyCode: modifier.virtualKeyCode,
          phase: .up,
          modifiers: activeModifiers
        )
      )
    }

    return events
  }
}

public protocol KeyboardEventPosting: Sendable {
  func post(_ event: KeyboardEventDescriptor) -> Bool
}

public struct CoreGraphicsKeyboardEventPoster: KeyboardEventPosting {
  public init() {}

  public func post(_ event: KeyboardEventDescriptor) -> Bool {
    guard
      let source = CGEventSource(stateID: .hidSystemState),
      let keyEvent = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(event.keyCode),
        keyDown: event.phase == .down
      )
    else {
      return false
    }

    keyEvent.flags = event.modifiers.cgEventFlags
    if event.kind == .modifier {
      keyEvent.type = .flagsChanged
    }
    keyEvent.post(tap: .cghidEventTap)
    return true
  }
}

public struct MacActionExecutor<Poster: KeyboardEventPosting>:
  ActionExecuting
{
  private let poster: Poster
  private let dictation: any DictationCommandDispatching
  private let localAIDictation: any DictationCommandDispatching

  public init(
    poster: Poster,
    dictation: any DictationCommandDispatching =
      UnavailableDictationCommandDispatcher(),
    localAIDictation: any DictationCommandDispatching =
      UnavailableDictationCommandDispatcher()
  ) {
    self.poster = poster
    self.dictation = dictation
    self.localAIDictation = localAIDictation
  }

  public func execute(_ invocation: ActionInvocation) -> Bool {
    switch invocation.action.kind {
    case .noAction:
      return true

    case .dictation:
      return dispatch(invocation.phase, to: dictation)

    case .localAIDictation:
      return dispatch(invocation.phase, to: localAIDictation)

    case .keyboardShortcut:
      guard
        invocation.phase == .perform,
        let shortcut = invocation.action.shortcut
      else {
        return false
      }
      return post(shortcut)
    }
  }

  public func shutdown() {
    dictation.shutdown()
    localAIDictation.shutdown()
  }

  private func dispatch(
    _ phase: ActionInvocationPhase,
    to dispatcher: any DictationCommandDispatching
  ) -> Bool {
    switch phase {
    case .begin:
      return dispatcher.submit(.begin)
    case .end:
      return dispatcher.submit(.finish)
    case .perform:
      return false
    }
  }

  private func post(_ shortcut: KeyboardShortcut) -> Bool {
    var succeeded = true
    for event in KeyboardEventPlan.events(for: shortcut) {
      if !poster.post(event) {
        succeeded = false
      }
    }
    return succeeded
  }
}

extension KeyModifier {
  fileprivate static let postingOrder: [KeyModifier] = [
    .control,
    .option,
    .shift,
    .command,
    .function,
  ]

  fileprivate var virtualKeyCode: UInt16 {
    switch self {
    case .command:
      55
    case .shift:
      56
    case .option:
      58
    case .control:
      59
    case .function:
      63
    }
  }
}

extension Set where Element == KeyModifier {
  fileprivate var cgEventFlags: CGEventFlags {
    reduce(into: CGEventFlags()) { result, modifier in
      switch modifier {
      case .command:
        result.insert(.maskCommand)
      case .option:
        result.insert(.maskAlternate)
      case .shift:
        result.insert(.maskShift)
      case .control:
        result.insert(.maskControl)
      case .function:
        result.insert(.maskSecondaryFn)
      }
    }
  }
}
