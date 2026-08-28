import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct VoiceKeyboardTriggerControllerTest {
  @Test
  func holdDispatchesBeginThenFinish() async throws {
    let dispatcher = DictationCommandRecorder()
    let controller = try VoiceKeyboardTriggerController(
      settings: .default,
      dispatcher: dispatcher
    )
    let start = MonotonicClock.nowNanoseconds()

    await controller.handle(
      phase: .pressed,
      timestampNanoseconds: start
    )
    await controller.handle(
      phase: .released,
      timestampNanoseconds: start + ms(300)
    )

    #expect(dispatcher.commands == [.begin, .finish])
  }

  @Test
  func doublePressLatchesThenTheNextDoublePressFinishesOnce() async throws {
    let dispatcher = DictationCommandRecorder()
    let controller = try VoiceKeyboardTriggerController(
      settings: .default,
      dispatcher: dispatcher
    )

    await controller.handle(phase: .pressed, timestampNanoseconds: ms(0))
    await controller.handle(phase: .released, timestampNanoseconds: ms(50))
    await controller.handle(phase: .pressed, timestampNanoseconds: ms(100))
    await controller.handle(phase: .released, timestampNanoseconds: ms(150))
    #expect(dispatcher.commands == [.begin])

    await controller.handle(phase: .pressed, timestampNanoseconds: ms(1_000))
    await controller.handle(phase: .released, timestampNanoseconds: ms(1_050))
    await controller.handle(phase: .pressed, timestampNanoseconds: ms(1_100))
    await controller.handle(phase: .released, timestampNanoseconds: ms(1_150))

    #expect(dispatcher.commands == [.begin, .finish])
  }

  @Test
  func pendingShortPressFinishesOnlyWhenItsDecisionExpires() async throws {
    let dispatcher = DictationCommandRecorder()
    let controller = try VoiceKeyboardTriggerController(
      settings: .default,
      dispatcher: dispatcher
    )
    let start = MonotonicClock.nowNanoseconds()
    await controller.handle(
      phase: .pressed,
      timestampNanoseconds: start
    )
    await controller.handle(
      phase: .released,
      timestampNanoseconds: start + ms(50)
    )

    await controller.decisionTimedOut(
      atNanoseconds: start + ms(400)
    )

    #expect(dispatcher.commands == [.begin, .finish])
  }

  @Test
  func interruptionCancelsActiveCaptureExactlyOnce() async throws {
    let dispatcher = DictationCommandRecorder()
    let controller = try VoiceKeyboardTriggerController(
      settings: .default,
      dispatcher: dispatcher
    )
    let start = MonotonicClock.nowNanoseconds()
    await controller.handle(
      phase: .pressed,
      timestampNanoseconds: start
    )

    await controller.interrupt()
    await controller.interrupt()

    #expect(dispatcher.commands == [.begin, .cancel])
  }

  private func ms(_ value: UInt64) -> UInt64 {
    value * 1_000_000
  }
}

private final class DictationCommandRecorder:
  DictationCommandDispatching,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var commandStorage: [DictationCommand] = []

  var commands: [DictationCommand] {
    lock.withLock { commandStorage }
  }

  func submit(_ command: DictationCommand) -> Bool {
    lock.withLock {
      commandStorage.append(command)
    }
    return true
  }

  func shutdown() {}
}
