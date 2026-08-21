import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct ActionExecutorTests {
  @Test
  func eventPlanPreservesKeyCodeAndModifiers() {
    let shortcut = KeyboardShortcut(
      keyCode: 15,
      modifiers: [.command, .shift]
    )

    let events = KeyboardEventPlan.events(for: shortcut)

    #expect(
      events == [
        KeyboardEventDescriptor(
          kind: .modifier,
          keyCode: 56,
          phase: .down,
          modifiers: [.shift]
        ),
        KeyboardEventDescriptor(
          kind: .modifier,
          keyCode: 55,
          phase: .down,
          modifiers: [.command, .shift]
        ),
        KeyboardEventDescriptor(
          keyCode: 15,
          phase: .down,
          modifiers: [.command, .shift]
        ),
        KeyboardEventDescriptor(
          keyCode: 15,
          phase: .up,
          modifiers: [.command, .shift]
        ),
        KeyboardEventDescriptor(
          kind: .modifier,
          keyCode: 55,
          phase: .up,
          modifiers: [.shift]
        ),
        KeyboardEventDescriptor(
          kind: .modifier,
          keyCode: 56,
          phase: .up,
          modifiers: []
        ),
      ]
    )
  }

  @Test
  func eventPlanPostsPhysicalModifierTransitions() {
    let shortcut = KeyboardShortcut(
      keyCode: 35,
      modifiers: [.control, .option]
    )

    let events = KeyboardEventPlan.events(for: shortcut)

    #expect(
      events == [
        KeyboardEventDescriptor(
          kind: .modifier,
          keyCode: 59,
          phase: .down,
          modifiers: [.control]
        ),
        KeyboardEventDescriptor(
          kind: .modifier,
          keyCode: 58,
          phase: .down,
          modifiers: [.control, .option]
        ),
        KeyboardEventDescriptor(
          keyCode: 35,
          phase: .down,
          modifiers: [.control, .option]
        ),
        KeyboardEventDescriptor(
          keyCode: 35,
          phase: .up,
          modifiers: [.control, .option]
        ),
        KeyboardEventDescriptor(
          kind: .modifier,
          keyCode: 58,
          phase: .up,
          modifiers: [.control]
        ),
        KeyboardEventDescriptor(
          kind: .modifier,
          keyCode: 59,
          phase: .up,
          modifiers: []
        ),
      ]
    )
  }

  @Test
  func shortcutPostsOnlyForPerformInvocation() {
    let poster = RecordingPoster()
    let dictation = RecordingDictationDispatcher()
    let executor = MacActionExecutor(
      poster: poster,
      dictation: dictation
    )
    let action = ActionConfiguration.keyboardShortcut(
      KeyboardShortcut(keyCode: 15, modifiers: [.command])
    )

    let success = executor.execute(
      invocation(action: action, phase: .perform)
    )
    let invalid = executor.execute(
      invocation(action: action, phase: .begin)
    )

    #expect(success)
    #expect(!invalid)
    #expect(poster.events.count == 4)
    #expect(dictation.commands.isEmpty)
  }

  @Test
  func dictationEnqueuesOwnedBeginAndFinishWithoutKeyboardEvents() {
    let poster = RecordingPoster()
    let dictation = RecordingDictationDispatcher()
    let executor = MacActionExecutor(
      poster: poster,
      dictation: dictation
    )
    let action = ActionConfiguration.dictation()

    #expect(
      executor.execute(
        invocation(action: action, phase: .begin)
      )
    )
    #expect(
      executor.execute(
        invocation(action: action, phase: .end)
      )
    )
    #expect(dictation.commands == [.begin, .finish])
    #expect(poster.events.isEmpty)
  }

  @Test
  func localAIDictationUsesOnlyItsDedicatedDispatcher() {
    let poster = RecordingPoster()
    let local = RecordingDictationDispatcher()
    let localAI = RecordingDictationDispatcher()
    let executor = MacActionExecutor(
      poster: poster,
      dictation: local,
      localAIDictation: localAI
    )

    #expect(
      executor.execute(
        invocation(action: .localAIDictation(), phase: .begin)
      )
    )
    #expect(
      executor.execute(
        invocation(action: .localAIDictation(), phase: .end)
      )
    )

    #expect(local.commands.isEmpty)
    #expect(localAI.commands == [.begin, .finish])
    #expect(poster.events.isEmpty)
  }

  @Test
  func failedPostStillAttemptsModifierRelease() {
    let poster = SelectivelyFailingPoster(failingAt: 1)
    let executor = MacActionExecutor(poster: poster)
    let action = ActionConfiguration.keyboardShortcut(
      KeyboardShortcut(
        keyCode: 35,
        modifiers: [.control, .option]
      )
    )

    let success = executor.execute(
      invocation(action: action, phase: .perform)
    )

    #expect(!success)
    #expect(poster.events.count == 6)
    #expect(poster.events.last?.modifiers.isEmpty == true)
  }

  private func invocation(
    action: ActionConfiguration,
    phase: ActionInvocationPhase
  ) -> ActionInvocation {
    ActionInvocation(
      deviceID: DeviceID(rawValue: "test"),
      controlID: .center,
      action: action,
      phase: phase,
      inputTimestampNanoseconds: 1
    )
  }
}

private final class SelectivelyFailingPoster:
  KeyboardEventPosting,
  @unchecked Sendable
{
  private let failingAt: Int
  private let lock = NSLock()
  private var storage: [KeyboardEventDescriptor] = []

  init(failingAt: Int) {
    self.failingAt = failingAt
  }

  var events: [KeyboardEventDescriptor] {
    lock.withLock { storage }
  }

  func post(_ event: KeyboardEventDescriptor) -> Bool {
    lock.withLock {
      storage.append(event)
      return storage.count - 1 != failingAt
    }
  }
}

private final class RecordingPoster:
  KeyboardEventPosting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storage: [KeyboardEventDescriptor] = []

  var events: [KeyboardEventDescriptor] {
    lock.withLock { storage }
  }

  func post(_ event: KeyboardEventDescriptor) -> Bool {
    lock.withLock {
      storage.append(event)
    }
    return true
  }
}

private final class RecordingDictationDispatcher:
  DictationCommandDispatching,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storage: [DictationCommand] = []

  var commands: [DictationCommand] {
    lock.withLock { storage }
  }

  func submit(_ command: DictationCommand) -> Bool {
    lock.withLock {
      storage.append(command)
    }
    return true
  }

  func shutdown() {}
}
